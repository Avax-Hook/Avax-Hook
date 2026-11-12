// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title HolderVestingModule
/// @notice Tokens a wallet buys early vest: they are locked, then after `cliff` unlock `stepBps` every `period`.
///         A wallet can never send or sell below its still-locked amount.
///   - Vesting buys: transfers FROM the PoolManager or the launchpad to a wallet (pool buys from any route,
///     curve buys, the creator's dev buy; also token claims and liquidity withdrawals paid out by the PoolManager)
///     during the first `earlyWindow` seconds after the launch (0 = every buy, ever), when the wallet's buys of
///     that transaction add up to at least `minBuyBps` of the supply (splitting one buy into several swaps of the
///     same transaction doesn't escape; separate small transactions do). Tokens received wallet-to-wallet are
///     free (not vested).
///   - Schedule per wallet: `base` and `start`. locked = base · (1 − unlocked), unlocked = 0 until start + cliff,
///     then stepBps per whole period, until 100%.
///   - More vesting buys: while some tokens are still locked (L), a new vesting buy A joins the existing schedule
///     (same start, base scaled so exactly L + A is locked right after the buy). Already scheduled tokens never
///     unlock later (anyone can buy tokens TO a wallet, so a buy must not be able to delay someone else's
///     schedule); the new tokens unlock along the existing schedule, so they can free up sooner than a fresh
///     schedule would, by at most the schedule's age (bounded by `earlyWindow` when it is set). Once a
///     wallet's schedule has fully unlocked, its next vesting buy starts a fresh one.
///   - Safety valve: every schedule ends at start + cliff + ceil(100% / stepBps) · period, bounded to 365 days, so
///     nothing is locked longer than 365 days after the schedule's start (a merge never extends it).
///   - Aggregators that receive bought tokens in their own contract before passing them on would hold the locked
///     tokens and can't pass them on, so qualifying aggregator buys revert during the window; buy on the curve or
///     through the AvaxHook router (tokens go straight to the buyer).
///   - Refusing sells and sends is the rule, so the module declares BLOCKS_SELLS.
///   Exempt: the PoolManager, the launchpad, the hook, 0x…dEaD, this module and the pool's other modules (Auto-LP vault, pots). The creator is not exempt.
///   - Claims bypass guard (2026-11-12): While buys vest (the `earlyWindow` after the launch, or forever), pool buys and sells that don't come through the
///     AvaxHook router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly():
///     such a swap can keep the tokens as PoolManager (ERC-6909) claims and sell them from there, which never move the
///     ERC-20, so this rule would never see them. Trade through the AvaxHook router (site, Zap, limit orders)
///     or the curve.
contract HolderVestingModule is HookModuleBase, TxTally {
    struct Config {
        uint32 earlyWindow; // seconds after the launch in which buys vest, 0 = all buys (max 365 days)
        uint16 minBuyBps; // smallest buy (one transaction) that vests, of the supply: 0 .. 10%
        uint32 cliff; // seconds before anything unlocks
        uint16 stepBps; // unlocked per period after the cliff: 0.01% .. 100%
        uint32 period; // seconds: 1 minute .. 30 days
    }

    struct Rule {
        Config cfg; // 16 bytes
        uint48 launchedAt;
        address token;
        bool registered;
    }

    struct Vest {
        uint128 base;
        uint64 start;
    }

    uint32 public constant MAX_WINDOW = 365 days;
    uint16 public constant MAX_MIN_BUY_BPS = 1_000;
    uint32 public constant MIN_PERIOD = 60;
    uint32 public constant MAX_PERIOD = 30 days;
    uint256 public constant MAX_SCHEDULE = 365 days;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.vesting.tx");

    mapping(PoolId => Rule) internal _rules;
    mapping(PoolId => mapping(address => Vest)) internal _vests;
    mapping(address => PoolId) public poolOf;

    event Vested(address indexed token, address indexed wallet, uint256 amount, uint256 locked, uint256 start);

    error StillLocked(address wallet, uint256 balance, uint256 locked);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS;
    }

    /// @dev Claims bypass guard: while buys vest, pool swaps must come through the AvaxHook router (BLOCKS_SELLS:
    ///      the revert stops sells too).
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        Rule storage r = _rules[ctx.poolId];
        uint32 w = r.cfg.earlyWindow;
        if (w == 0 || block.timestamp < uint256(r.launchedAt) + w) RouterOnlyGuard.check(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SELL_LOCK;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.earlyWindow > MAX_WINDOW || c.minBuyBps > MAX_MIN_BUY_BPS) revert BadConfig();
        if (c.stepBps == 0 || c.stepBps > BPS || c.period < MIN_PERIOD || c.period > MAX_PERIOD) revert BadConfig();
        if (_scheduleLength(c) > MAX_SCHEDULE) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.launchedAt = uint48(block.timestamp);
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
        Rule storage r = _rules[id];
        Config memory c = r.cfg;
        // outgoing: never below the still-locked amount
        Vest memory v = _vests[id][from];
        if (v.base != 0 && !_plumbing(id, from, pad)) {
            uint256 lock = _locked(c, v);
            uint256 bal = IERC20(token).balanceOf(from);
            if (bal < lock) revert StillLocked(from, bal, lock);
        }
        // incoming buy inside the window: vests
        if ((from != address(poolManager) && from != pad) || _plumbing(id, to, pad)) return;
        if (c.earlyWindow != 0 && block.timestamp >= uint256(r.launchedAt) + c.earlyWindow) return;
        uint256 total = _tallyAdd(keccak256(abi.encode(TALLY, id, to)), amount);
        uint256 min = (TOTAL_SUPPLY * c.minBuyBps) / BPS;
        if (total < min) return;
        // the buy that crosses the minimum vests the whole transaction's buys
        _add(id, to, c, total - amount < min ? total : amount, IERC20(token).balanceOf(to));
    }

    // ---------------------------------------------------------------- views

    /// @return locked   tokens `wallet` can't send or sell now
    /// @return base     schedule base
    /// @return start    schedule start (0 = never vested)
    /// @return unlockAt when everything is unlocked
    function vestingOf(address token, address wallet)
        external
        view
        returns (uint256 locked, uint256 base, uint256 start, uint256 unlockAt)
    {
        PoolId id = poolOf[token];
        Config memory c = _rules[id].cfg;
        Vest memory v = _vests[id][wallet];
        if (v.base == 0) return (0, 0, 0, 0);
        return (_locked(c, v), v.base, v.start, v.start + _scheduleLength(c));
    }

    /// @notice Tokens `wallet` may send or sell now.
    function transferable(address token, address wallet) external view returns (uint256) {
        PoolId id = poolOf[token];
        uint256 lock = _locked(_rules[id].cfg, _vests[id][wallet]);
        uint256 bal = IERC20(token).balanceOf(wallet);
        return bal > lock ? bal - lock : 0;
    }

    /// @notice Whether a buy now would vest (inside the early window).
    function vestingOpen(address token) external view returns (bool) {
        Rule storage r = _rules[poolOf[token]];
        return r.registered && (r.cfg.earlyWindow == 0 || block.timestamp < uint256(r.launchedAt) + r.cfg.earlyWindow);
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    function _add(PoolId id, address wallet, Config memory c, uint256 amount, uint256 balance) internal {
        Vest storage s = _vests[id][wallet];
        Vest memory v = s;
        uint256 l = _locked(c, v);
        // never lock more than the wallet holds (it may have sent tokens away earlier in the transaction)
        uint256 room = balance > l ? balance - l : 0;
        if (amount > room) amount = room;
        if (amount == 0) return;
        uint256 total = l + amount;
        uint256 start;
        uint256 base;
        if (l == 0) {
            (start, base) = (block.timestamp, amount); // nothing left locked: a fresh schedule
        } else {
            // Merge into the existing schedule without moving it (L-1: a third party buying to this wallet must
            // never delay tokens already scheduled): same start, base scaled so exactly L + A is locked now.
            // locked'(t) = (L + A) · (1 − f(t)) / (1 − f(now)) <= locked(t) + A for every later t (up to 2 wei
            // of rounding), so no earlier token unlocks later; the new tokens follow the existing schedule.
            start = v.start;
            uint256 f = _unlockedBps(c, block.timestamp - start); // < BPS: l > 0
            base = (total * BPS + (BPS - f) - 1) / (BPS - f); // exactly `total` locked now
        }
        s.base = uint128(base);
        s.start = uint64(start);
        emit Vested(_rules[id].token, wallet, amount, total, start);
    }

    function _locked(Config memory c, Vest memory v) internal view returns (uint256) {
        if (v.base == 0) return 0;
        uint256 f = _unlockedBps(c, block.timestamp - v.start);
        return (uint256(v.base) * (BPS - f)) / BPS;
    }

    function _unlockedBps(Config memory c, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed < c.cliff) return 0;
        uint256 f = ((elapsed - c.cliff) / c.period) * c.stepBps;
        return f > BPS ? BPS : f;
    }

    function _scheduleLength(Config memory c) internal pure returns (uint256) {
        return uint256(c.cliff) + ((BPS + c.stepBps - 1) / c.stepBps) * c.period;
    }

    /// @dev Protocol plumbing, including the pool's own modules (Auto-LP's claims, adds and fee takes).
    function _plumbing(PoolId id, address a, address pad) internal view returns (bool) {
        return a == address(poolManager) || a == pad || a == hook || a == ModuleCaps.BURN || a == address(this)
            || a == address(0) || PoolModules.isModule(hook, id, a);
    }
}
