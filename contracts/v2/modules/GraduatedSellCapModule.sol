// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title GraduatedSellCapModule
/// @notice A per-sell cap that shrinks with the seller's bag: the bigger the holder, the smaller the slice of
///         supply it may sell in one transaction.
///           bag <= smallBag -> cap = smallCap;  bag >= whaleBag -> cap = floorCap;  linear in between.
///         Bag = the seller's largest balance before any of its sells in the transaction; all its sells in one
///         transaction count together (transient storage), so splitting a sell into several swaps doesn't help.
///   - A sell is any transfer TO the PoolManager or the launchpad (pool sells from any route, curve sells; adding
///     liquidity moves tokens into the PoolManager and counts too). The cap is per transaction: a whale can still
///     exit in steps, and every step shrinks its bag, so its cap grows back.
///   - Refusing sells is the rule, so the module declares BLOCKS_SELLS. It applies from the launch (curve sells
///     included) until `duration` seconds after the pool opens (0 = forever, max 365 days).
///   - Splitting the bag across wallets lifts the cap (each wallet is a small bag). Aggregators that pull tokens
///     into their own contract first sell as that contract: its bag is what it was handed.
///   Exempt senders: the PoolManager, the launchpad, the hook, 0x…dEaD, this module and the pool's other modules (Auto-LP vault, pots). The creator is not.
///   - Claims bypass guard (2026-11-12): While the cap applies (`duration` after the pool opens, or forever), pool buys and sells that don't come through the
///     AvaxHook router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly():
///     such a swap can keep the tokens as PoolManager (ERC-6909) claims and sell them from there, which never move the
///     ERC-20, so this rule would never see them. Trade through the AvaxHook router (site, Zap, limit orders)
///     or the curve.
contract GraduatedSellCapModule is HookModuleBase, TxTally {
    struct Config {
        uint16 smallBagBps; // bags up to this (of the 1B supply) get the full cap: 0.01% .. 50%
        uint16 smallCapBps; // cap per sell for small bags, of the supply: 0.01% .. 50%
        uint16 whaleBagBps; // bags from this on get the floor cap: > smallBag .. 100%
        uint16 floorCapBps; // cap per sell for whales: 0.01% .. smallCap
        uint32 duration; // seconds after the pool opens, 0 = forever (max 365 days)
    }

    struct Rule {
        Config cfg; // 12 bytes
        address token;
        bool registered;
    }

    uint16 public constant MAX_SMALL_BAG_BPS = 5_000;
    uint16 public constant MAX_CAP_BPS = 5_000;
    uint32 public constant MAX_DURATION = 365 days;
    bytes32 internal constant BAG = keccak256("avaxhook.v2.gradsell.bag");
    bytes32 internal constant SOLD = keccak256("avaxhook.v2.gradsell.sold");

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    error SellCapExceeded(address seller, uint256 sold, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS;
    }

    /// @dev Claims bypass guard: while the cap applies, pool swaps must come through the AvaxHook router
    ///      (BLOCKS_SELLS: the revert stops sells too).
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (_active(ctx.poolId, _rules[ctx.poolId].cfg.duration)) RouterOnlyGuard.check(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SELL_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.smallBagBps == 0 || c.smallBagBps > MAX_SMALL_BAG_BPS) revert BadConfig();
        if (c.whaleBagBps <= c.smallBagBps || c.whaleBagBps > BPS) revert BadConfig();
        if (c.smallCapBps == 0 || c.smallCapBps > MAX_CAP_BPS) revert BadConfig();
        if (c.floorCapBps == 0 || c.floorCapBps > c.smallCapBps) revert BadConfig();
        if (c.duration > MAX_DURATION) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.token = token;
        r.registered = true;
        poolOf[token] = id;
    }

    function onTransfer(PoolId id, address token, address, address from, address to, uint256 amount)
        external
        override
        onlyHook
    {
        if (amount == 0) return;
        address pad = IAvaxHookV2View(hook).launchpad();
        if (to != address(poolManager) && to != pad) return;
        if (from == address(poolManager) || from == pad || from == hook || from == ModuleCaps.BURN || from == address(this)) {
            return;
        }
        Rule storage r = _rules[id];
        Config memory c = r.cfg;
        if (!_active(id, c.duration)) return;
        if (PoolModules.isModule(hook, id, from)) return; // Auto-LP adding liquidity, pots: not a sell
        bytes32 bagKey = keccak256(abi.encode(BAG, id, from));
        // Bag = the larger of the balance before the first sell of the transaction and the balance before this
        // sell: tokens pulled back in after a dust first sell (from a second wallet) still count.
        uint256 bag = _tload(bagKey);
        uint256 before = IERC20(token).balanceOf(from) + amount; // balance before this sell
        if (bag == 0 || before > bag - 1) {
            bag = before;
            _tstore(bagKey, bag + 1);
        } else {
            bag -= 1;
        }
        uint256 sold = _tallyAdd(keccak256(abi.encode(SOLD, id, from)), amount);
        uint256 cap = _capForBag(c, bag);
        if (sold > cap) revert SellCapExceeded(from, sold, cap);
    }

    // ---------------------------------------------------------------- views

    /// @notice Largest sell (tokens, one transaction) `wallet` may make now with its current balance.
    /// @return cap    tokens
    /// @return active whether the rule still applies
    function sellCapOf(address token, address wallet) external view returns (uint256 cap, bool active) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        if (!r.registered) return (0, false);
        return (_capForBag(r.cfg, IERC20(token).balanceOf(wallet)), _active(id, r.cfg.duration));
    }

    /// @notice The cap (tokens) a bag of `bag` tokens gets.
    function capForBag(address token, uint256 bag) external view returns (uint256) {
        return _capForBag(_rules[poolOf[token]].cfg, bag);
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    function _capForBag(Config memory c, uint256 bag) internal pure returns (uint256) {
        uint256 small = (TOTAL_SUPPLY * c.smallBagBps) / BPS;
        uint256 whale = (TOTAL_SUPPLY * c.whaleBagBps) / BPS;
        uint256 hi = (TOTAL_SUPPLY * c.smallCapBps) / BPS;
        uint256 lo = (TOTAL_SUPPLY * c.floorCapBps) / BPS;
        if (bag <= small) return hi;
        if (bag >= whale) return lo;
        // linear from hi at `small` down to lo at `whale`; rounds down (against the seller)
        return hi - ((hi - lo) * (bag - small) + (whale - small) - 1) / (whale - small);
    }

    function _active(PoolId id, uint32 duration) internal view returns (bool) {
        if (duration == 0) return true;
        uint256 opened = _openedAt(id);
        return opened == 0 || block.timestamp < opened + duration;
    }
}
