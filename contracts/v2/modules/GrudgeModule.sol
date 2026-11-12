// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title GrudgeModule ("The grudge")
/// @notice The token remembers dumpers. A dump is one transaction in which a wallet sells, net of tokens it
///         received in the same transaction (minus what it sent away in it), at least `dumpBps` of its bag and at
///         least MIN_DUMP (0.01% of the supply). The bag is the wallet's balance before its first token move (in
///         or out) of the transaction, snapshotted in transient storage; self-transfers are ignored. The dumper is
///         held a grudge until now + grudgeTime · 2^(dumps − 1), capped at
///         `maxGrudgeTime` (at most 30 days). While the grudge lasts, the penalty `mode` applies:
///           0 BUY_BAN  the wallet can't buy: transfers to it from the PoolManager or the launchpad are refused
///                      (pool buys from any route, curve buys; also token claims and liquidity withdrawals)
///           1 BUY_TAX  its buys pay `taxBps` of the quote input, donated to the pool's liquidity (on the curve:
///                      to the graduation liquidity). Only buys where the buyer is known are taxed: the curve and
///                      the AvaxHook router; aggregator buys can't be taxed
///           2 CAP      it may hold at most `capBps` of the supply (buys and transfers in)
///   - Sells are never blocked: the module has no BLOCKS_SELLS, it only takes notes on the sell path.
///   - A sell is a transfer TO the PoolManager or the launchpad. Aggregators that first pull your tokens into
///     their own contract sell as that contract, and what they pass on in the same transaction is not their
///     dump, so such sells are not seen as anyone's dump (that also keeps aggregator contracts from being
///     grudged and breaking routing, even when someone gifts them dust first). Bouncing tokens A -> B -> A
///     inside the transaction doesn't hide a dump (tokens that come back net against what was sent). Moving the
///     bag to a fresh wallet in an earlier transaction gets around it. An aggregator that sweeps its whole
///     balance into a sell can still be grudged by someone gifting it >= MIN_DUMP tokens first.
///   Exempt: the PoolManager, the launchpad, the hook, 0x…dEaD, this module and the pool's other modules (Auto-LP vault, pots). The creator is not exempt.
///   - Claims bypass guard (2026-11-12): While any wallet of the pool is under a grudge (`grudgeLiveUntil`), pool buys that don't come through the
///     AvaxHook router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly():
///     such a swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the
///     ERC-20, so this rule would never see them. Trade through the AvaxHook router (site, Zap, limit orders)
///     or the curve.
contract GrudgeModule is HookModuleBase, TxTally {
    struct Config {
        uint16 dumpBps; // share of the bag sold in one transaction that counts as a dump: 10% .. 100%
        uint32 grudgeTime; // first grudge, seconds: 1 minute .. maxGrudgeTime
        uint32 maxGrudgeTime; // longest grudge (repeats double it up to this): .. 30 days
        uint8 mode; // 0 buy ban, 1 buy tax, 2 holding cap
        uint16 taxBps; // mode 1: share of the buy's quote input, 0.01% .. 25%; else 0
        uint16 capBps; // mode 2: max holding while grudged, of the supply, 0.01% .. 50%; else 0
    }

    struct Rule {
        Config cfg; // 16 bytes
        address token;
        bool registered;
    }

    struct Grudge {
        uint64 until;
        uint32 count;
    }

    uint8 public constant BUY_BAN = 0;
    uint8 public constant BUY_TAX = 1;
    uint8 public constant CAP = 2;
    uint16 public constant MIN_DUMP_BPS = 1_000;
    uint32 public constant MIN_GRUDGE = 60;
    uint32 public constant MAX_GRUDGE = 30 days;
    /// @dev The core caps all module cuts of one side at 25% (MAX_MODULE_CUT_BPS); a higher tax would be scaled.
    uint16 public constant MAX_TAX_BPS = 2_500;
    uint16 public constant MAX_CAP_BPS = 5_000;
    bytes32 internal constant RECV = keccak256("avaxhook.v2.grudge.recv");
    bytes32 internal constant BAG = keccak256("avaxhook.v2.grudge.bag");
    bytes32 internal constant SOLD = keccak256("avaxhook.v2.grudge.sold");
    bytes32 internal constant FLAG = keccak256("avaxhook.v2.grudge.flag");
    bytes32 internal constant SENT = keccak256("avaxhook.v2.grudge.sent");
    /// @dev Sells under 0.01% of the supply (net) are never a dump, so gifting dust can't poison a wallet.
    uint256 public constant MIN_DUMP = 100_000 ether;

    mapping(PoolId => Rule) internal _rules;
    mapping(PoolId => mapping(address => Grudge)) internal _grudges;
    mapping(address => PoolId) public poolOf;
    /// @notice The latest grudge end of the pool: until then pool buys must come through the AvaxHook router.
    mapping(PoolId => uint256) public grudgeLiveUntil;

    event Grudged(address indexed token, address indexed wallet, uint256 until, uint256 count);

    error BuyBanned(address wallet, uint256 until);
    error GrudgeCapExceeded(address wallet, uint256 balance, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.dumpBps < MIN_DUMP_BPS || c.dumpBps > BPS) revert BadConfig();
        if (c.maxGrudgeTime > MAX_GRUDGE || c.grudgeTime < MIN_GRUDGE || c.grudgeTime > c.maxGrudgeTime) revert BadConfig();
        if (c.mode > CAP) revert BadConfig();
        if (c.mode == BUY_TAX ? (c.taxBps == 0 || c.taxBps > MAX_TAX_BPS) : c.taxBps != 0) revert BadConfig();
        if (c.mode == CAP ? (c.capBps == 0 || c.capBps > MAX_CAP_BPS) : c.capBps != 0) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.token = token;
        r.registered = true;
        poolOf[token] = id;
    }

    /// @dev Mode 1: a known buyer under a grudge pays the tax from the quote input.
    ///      Claims bypass guard: while any grudge of the pool is live, pool buys must come through the router (an
    ///      unknown buyer could be a grudged wallet keeping its buy as PoolManager claims).
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy && grudgeLiveUntil[ctx.poolId] > block.timestamp) RouterOnlyGuard.check(ctx);
        if (!ctx.isBuy || ctx.trader == address(0)) return (0, new Credit[](0));
        Config memory c = _rules[ctx.poolId].cfg;
        if (c.mode != BUY_TAX || _grudges[ctx.poolId][ctx.trader].until <= block.timestamp) return (0, new Credit[](0));
        uint256 tax = (ctx.amountIn * c.taxBps) / BPS;
        return (0, tax == 0 ? new Credit[](0) : _one(ModuleCaps.LP_DONATE, tax));
    }

    function onTransfer(PoolId id, address token, address, address from, address to, uint256 amount)
        external
        override
        onlyHook
    {
        if (amount == 0 || from == to) return; // a self-transfer changes nothing
        address pad = IAvaxHookV2View(hook).launchpad();
        Config memory c = _rules[id].cfg;
        bool fromWallet = !_plumbing(id, from, pad);
        bool toWallet = !_plumbing(id, to, pad);
        if (fromWallet) {
            _snapshot(id, from, IERC20(token).balanceOf(from) + amount);
            if (toWallet) _tallyAdd(keccak256(abi.encode(SENT, id, from)), amount);
        }
        if (toWallet) {
            uint256 bal = IERC20(token).balanceOf(to);
            _snapshot(id, to, bal - amount);
            _tallyAdd(keccak256(abi.encode(RECV, id, to)), amount);
            uint256 until = _grudges[id][to].until;
            if (until > block.timestamp) {
                if (c.mode == BUY_BAN && (from == address(poolManager) || from == pad)) revert BuyBanned(to, until);
                if (c.mode == CAP) {
                    uint256 cap = (TOTAL_SUPPLY * c.capBps) / BPS;
                    if (bal > cap) revert GrudgeCapExceeded(to, bal, cap);
                }
            }
            return;
        }
        if (!fromWallet || (to != address(poolManager) && to != pad)) return;
        // a sell: never refused, only noted (this runs isolated on the sell path)
        uint256 bag = _snapshot(id, from, 0); // already taken above: the balance before the first touch
        if (bag == 0) return; // only passing on what it received in this transaction
        uint256 sold = _tallyAdd(keccak256(abi.encode(SOLD, id, from)), amount);
        // tokens that came in during this transaction (net of what it sent away) are passed on, not dumped
        uint256 recv = _tload(keccak256(abi.encode(RECV, id, from)));
        uint256 sent = _tload(keccak256(abi.encode(SENT, id, from)));
        uint256 newIn = recv > sent ? recv - sent : 0;
        uint256 net = sold > newIn ? sold - newIn : 0;
        if (net < MIN_DUMP || net * BPS < bag * c.dumpBps) return;
        bytes32 flagKey = keccak256(abi.encode(FLAG, id, from)); // one grudge per transaction
        if (_tload(flagKey) != 0) return;
        _tstore(flagKey, 1);
        _grudge(id, from, c);
    }

    // ---------------------------------------------------------------- views

    /// @return until  the grudge lasts until (0 or past = no grudge)
    /// @return count  dumps remembered
    /// @return active whether the penalty applies now
    function grudgeOf(address token, address wallet) external view returns (uint256 until, uint256 count, bool active) {
        Grudge memory g = _grudges[poolOf[token]][wallet];
        return (g.until, g.count, g.until > block.timestamp);
    }

    /// @notice How long the next grudge of `wallet` would last.
    function nextGrudgeTime(address token, address wallet) external view returns (uint256) {
        PoolId id = poolOf[token];
        return _duration(_rules[id].cfg, _grudges[id][wallet].count + 1);
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    /// @dev The wallet's balance before its first touch (in or out) in this transaction; `before` is used
    ///      only on that first touch.
    function _snapshot(PoolId id, address wallet, uint256 before) internal returns (uint256) {
        bytes32 k = keccak256(abi.encode(BAG, id, wallet));
        uint256 v = _tload(k);
        if (v != 0) return v - 1;
        _tstore(k, before + 1);
        return before;
    }

    function _grudge(PoolId id, address wallet, Config memory c) internal {
        Grudge storage g = _grudges[id][wallet];
        uint32 n = g.count < type(uint32).max ? g.count + 1 : g.count;
        uint256 until = block.timestamp + _duration(c, n);
        if (until < g.until) until = g.until;
        g.count = n;
        g.until = uint64(until);
        if (until > grudgeLiveUntil[id]) grudgeLiveUntil[id] = until;
        emit Grudged(_rules[id].token, wallet, until, n);
    }

    function _duration(Config memory c, uint256 n) internal pure returns (uint256 d) {
        if (n == 0) return 0;
        d = n > 32 ? type(uint256).max : uint256(c.grudgeTime) << (n - 1);
        if (d > c.maxGrudgeTime) d = c.maxGrudgeTime;
    }

    /// @dev Protocol plumbing, including the pool's own modules (Auto-LP's claims, adds and fee takes).
    function _plumbing(PoolId id, address a, address pad) internal view returns (bool) {
        return a == address(poolManager) || a == pad || a == hook || a == ModuleCaps.BURN || a == address(this)
            || a == address(0) || PoolModules.isModule(hook, id, a);
    }
}
