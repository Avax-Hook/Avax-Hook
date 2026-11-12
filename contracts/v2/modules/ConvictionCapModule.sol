// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {ReceiverRuleBase} from "./ReceiverRuleBase.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title ConvictionCapModule
/// @notice A per-wallet buy cap that grows the longer the wallet has held without selling or sending:
///         cap = min(ceiling, start + growthBps · heldTime / growthPeriod), of the 1B supply.
///   - Clock: starts at the wallet's first receive (buy or transfer in). Any outgoing transfer (a sell, a send,
///     adding liquidity) restarts it; emptying the wallet stops it until the next receive.
///   - A buy is any transfer FROM the PoolManager or the launchpad to a wallet (pool buys from any route,
///     curve buys; also token claims paid out by the PoolManager). All buys a wallet
///     receives in one transaction count together (transient storage), so splitting a buy doesn't help.
///     Across transactions it's per buy: buying again in the next transaction is allowed.
///   - LP withdrawals and fee collects of THIS pool are not buys: the module declares LIQUIDITY and a removal
///     grants this transaction an allowance (see ReceiverRuleBase: principal at the current price + owed token
///     fees; none in a transaction that also adds liquidity to this pool). A PoolManager payout that would break
///     the cap uses that allowance instead of reverting, so a big LP can withdraw in one transaction.
///   - Applies from the launch (curve buys and the creator's dev buy included) until `duration` seconds
///     after the pool opens (0 = forever). Sells are never capped.
///   - Aggregators that receive the tokens themselves and pass them on count as the buying wallet: their clock
///     restarts on every pass-through, so they get the starting cap. A wallet aged with a dust balance keeps its
///     clock, and splitting across wallets multiplies the cap; the rule slows whales, it can't stop them.
///   Exempt: the PoolManager, the launchpad, the hook, 0x…dEaD, this module and the pool's other modules (Auto-LP vault, pots). The creator is not exempt.
///   - Claims bypass guard (2026-11-12): While the cap applies (`duration` after the pool opens, or forever), pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract ConvictionCapModule is ReceiverRuleBase, TxTally {
    struct Config {
        uint16 startBps; // cap for a fresh wallet, of the 1B supply: 0.01% .. 10%
        uint16 growthBps; // added per growthPeriod held: 0.01% .. 10%
        uint32 growthPeriod; // seconds: 1 minute .. 30 days
        uint16 ceilingBps; // the cap never grows past this: start .. 50%
        uint32 duration; // seconds after the pool opens, 0 = forever (max 365 days)
    }

    struct Rule {
        Config cfg; // 14 bytes
        address token;
        bool registered;
    }

    uint16 public constant MAX_START_BPS = 1_000;
    uint16 public constant MAX_GROWTH_BPS = 1_000;
    uint32 public constant MIN_PERIOD = 60;
    uint32 public constant MAX_PERIOD = 30 days;
    uint16 public constant MAX_CEILING_BPS = 5_000;
    uint32 public constant MAX_DURATION = 365 days;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.conviction.tx");

    mapping(PoolId => Rule) internal _rules;
    mapping(PoolId => mapping(address => uint256)) internal _since;
    mapping(address => PoolId) public poolOf;

    error BuyCapExceeded(address wallet, uint256 bought, uint256 cap);

    constructor(address _hook) ReceiverRuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY;
    }

    /// @dev Claims bypass guard: while the cap applies, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy && _active(ctx.poolId, _rules[ctx.poolId].cfg.duration)) RouterOnlyGuard.check(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_BUY_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.startBps == 0 || c.startBps > MAX_START_BPS) revert BadConfig();
        if (c.growthBps == 0 || c.growthBps > MAX_GROWTH_BPS) revert BadConfig();
        if (c.growthPeriod < MIN_PERIOD || c.growthPeriod > MAX_PERIOD) revert BadConfig();
        if (c.ceilingBps < c.startBps || c.ceilingBps > MAX_CEILING_BPS) revert BadConfig();
        if (c.duration > MAX_DURATION) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config)
        external
        override
        onlyHook
    {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        _registerPool(id, token, quote);
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
        mapping(address => uint256) storage since = _since[id];
        // the sender's clock restarts (or stops when it's empty)
        if (!_plumbing(id, from, pad)) since[from] = IERC20(token).balanceOf(from) == 0 ? 0 : block.timestamp;
        if (_plumbing(id, to, pad)) return;
        uint256 s = since[to];
        if ((from == address(poolManager) || from == pad) && _active(id, _rules[id].cfg.duration)) {
            uint256 cap = _capFor(_rules[id].cfg, s);
            bytes32 k = keccak256(abi.encode(TALLY, id, to));
            uint256 bought = _tallyAdd(k, amount);
            if (bought > cap) {
                // an LP withdrawal / fee collect of this pool covered by this transaction's allowance: not a buy
                if (from != address(poolManager) || !_useAllowance(id, amount)) revert BuyCapExceeded(to, bought, cap);
                _tstore(k, bought - amount);
            }
        }
        if (s == 0) since[to] = block.timestamp;
    }

    // ---------------------------------------------------------------- views

    /// @return cap    the largest buy (tokens received, one transaction) `wallet` may make now
    /// @return since  when its clock started (0 = no clock yet: the starting cap)
    /// @return active whether the rule still applies
    function capOf(address token, address wallet) external view returns (uint256 cap, uint256 since, bool active) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        if (!r.registered) return (0, 0, false); // not a token of this module
        since = _since[id][wallet];
        return (_capFor(r.cfg, since), since, r.registered && _active(id, r.cfg.duration));
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    function _capFor(Config memory c, uint256 since) internal view returns (uint256) {
        uint256 held = since == 0 ? 0 : block.timestamp - since;
        uint256 bps = uint256(c.startBps) + (uint256(c.growthBps) * held) / c.growthPeriod;
        if (bps > c.ceilingBps) bps = c.ceilingBps;
        return (TOTAL_SUPPLY * bps) / BPS;
    }

    function _active(PoolId id, uint32 duration) internal view returns (bool) {
        if (duration == 0) return true;
        uint256 opened = _openedAt(id);
        return opened == 0 || block.timestamp < opened + duration;
    }

    /// @dev Protocol plumbing, including the pool's own modules (Auto-LP's claims, adds and fee takes).
    function _plumbing(PoolId id, address a, address pad) internal view returns (bool) {
        return a == address(poolManager) || a == pad || a == hook || a == ModuleCaps.BURN || a == address(this)
            || a == address(0) || PoolModules.isModule(hook, id, a);
    }
}
