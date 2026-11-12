// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title LockEarnModule
/// @notice Holders lock tokens in their own wallet and earn `bps` of every trade's quote amount (buys: from
///         the input, sells: from the output; curve and pool, every route), pro-rata to the amount locked.
///   - `lock(token, amount, unlockAt)`: locks `amount` more of your balance (0 to only extend) until
///     `unlockAt`, at least `minLock` from now and at most 365 days. Unlock times are rounded up to the next
///     00:00 UTC (locks expire in daily batches), so a lock can run to about 366 days. An active lock can grow
///     and be extended, never shortened.
///   - While locked, the token refuses any move (sell, send, LP add) that would leave the wallet below its
///     locked amount (BLOCKS_SELLS). At the unlock time the tokens are free again on their own; nothing to
///     call. The 365-day cap means no lock lasts forever.
///   - Earnings: a dividend-per-share index over locked amounts. A lock earns from the moment it is made until
///     its unlock time and not after: the index is snapshotted when each daily batch expires (lazily, by the
///     next trade, lock, claim or `poke`; at most MAX_STEPS batches per trade, so after an idle stretch that
///     crosses more than MAX_STEPS unlock days, the trades just before a `poke` may still count locks that
///     have already expired, which only shifts a sliver between lockers). `claim(token)` pays everything
///     earned in the quote asset straight to your wallet.
///     In other words: an expired lock can keep earning a little until its batch is recorded.
///   - Fees that arrive while nobody is locked carry forward: they join the index at the next fold with
///     lockers (the first lockers after a quiet spell get them). Carry that still found no locker 180 days
///     after the last unlock can be swept to the creator by anyone (`sweepCarry`), so it never strands.
///   - Fees are this module's claim in the hook, folded into the index once the hook's books confirm them
///     (LedgerModuleBase); claims withdraw the module's claim into its own balance (`cash`) and pay from it.
///   - Not identity-neutral (transfer rule). Group SELL_LOCK (no other lock-style rule in the same launch).
///   - Kill switch: if the registry disables the module the hook stops calling it, so locks are no longer
///     enforced and fees stop; earnings stay claimable (`rescue` has nothing to move).
contract LockEarnModule is LedgerModuleBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Config {
        uint16 bps; // of each trade's quote amount: 0.01% .. 5%
        uint32 minLock; // seconds: 1 hour .. 180 days
    }

    struct Pool {
        // slot 0
        address token;
        uint16 bps;
        uint32 minLock;
        bool live;
        // slot 1
        address quote;
        uint64 lastDay; // unlock days up to and including this one are expired and snapshotted
        // slot 2
        uint128 unverified; // credits announced to the hook, not yet checked against its books
        uint128 carry; // confirmed, waiting for lockers
        // slot 3
        uint128 totalShares; // locked and not yet expired
        uint128 distributed; // folded into the index
        // slot 4
        uint256 perShare; // magnified (MAG) cumulative earnings per locked token, < 2^160
        // slot 5
        uint128 paid;
        uint64 maxUnlock; // latest unlock time of any lock (launch time until the first)
        // slot 6
        address creator;
    }

    struct Locker {
        uint96 amount; // 0 = no lock
        uint160 ps0; // index at the last settle
        uint32 day; // unlock day (unlock time = day × 1 days)
        uint128 owed; // settled, not yet paid
    }

    struct Batch {
        uint96 expiring; // locked amount that unlocks on this day
        uint160 snap; // index when it expired
    }

    uint16 public constant MAX_BPS = 500;
    uint32 public constant MIN_LOCK_FLOOR = 1 hours;
    uint32 public constant MIN_LOCK_CEIL = 180 days;
    uint32 public constant MAX_LOCK = 365 days;
    /// @notice Unlock-day batches a trade expires at most (lock, claim and poke expire all).
    uint256 public constant MAX_STEPS = 8;
    /// @notice Carry left with no lockers this long after the last unlock goes to the creator (`sweepCarry`).
    uint256 public constant SWEEP_AFTER = 180 days;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant MAG = 2 ** 64;
    /// @dev Credits wait in `carry` until at least one whole token is locked (no dust-denominator jumps).
    uint256 internal constant MIN_FOLD_SHARES = 1 ether;

    mapping(PoolId => Pool) internal _pools;
    mapping(address => PoolId) public poolOf;
    mapping(PoolId => mapping(address => Locker)) internal _lockers;
    mapping(PoolId => mapping(uint256 => Batch)) internal _batches;
    /// @dev pool => word (day >> 8) => bit per day with a batch
    mapping(PoolId => mapping(uint256 => uint256)) internal _days;
    /// @notice Quote this module holds itself (withdrawn from the hook, not yet paid), per quote asset.
    mapping(address => uint256) public cash;

    event Registered(address indexed token, PoolId id, address quote, uint16 bps, uint32 minLock);
    event Locked(address indexed token, address indexed holder, uint256 amount, uint256 unlockAt);
    event Claimed(address indexed token, address indexed holder, uint256 amount);
    event CarrySwept(address indexed token, address indexed creator, uint256 amount);

    error UnknownToken();
    error LockedTokens(uint256 locked, uint256 unlockAt);
    error BadLock();
    error NothingOwed();
    error SendFailed();

    constructor(address _hook) LedgerModuleBase(_hook) {}

    receive() external payable {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SELL_LOCK;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.bps == 0 || c.bps > MAX_BPS) revert BadConfig();
        if (c.minLock < MIN_LOCK_FLOOR || c.minLock > MIN_LOCK_CEIL) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external override onlyHook {
        Pool storage p = _pools[id];
        if (p.live) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (p.token, p.bps, p.minLock, p.live) = (token, c.bps, c.minLock, true);
        (p.quote, p.lastDay) = (quote, uint64(block.timestamp / DAY));
        (p.creator, p.maxUnlock) = (creator, uint64(block.timestamp));
        poolOf[token] = id;
        _seed(quote);
        emit Registered(token, id, quote, c.bps, c.minLock);
    }

    // ---------------------------------------------------------------- accrual (never reverts: sells run it)

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _accrue(ctx.poolId, ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _accrue(ctx.poolId, ctx.amountOut);
    }

    function _accrue(PoolId id, uint256 amount) internal returns (Credit[] memory) {
        _reconcile(); // folds the last confirmed credit at the shares of its own trade
        Pool storage p = _pools[id];
        _advance(id, p, MAX_STEPS);
        uint256 share = (amount * p.bps) / BPS;
        if (share == 0) return new Credit[](0);
        p.unverified += uint128(share);
        _expect(id, p.quote, share);
        return _one(address(this), share);
    }

    // ---------------------------------------------------------------- the lock

    /// @dev Refuses moves that would leave an active locker below its locked amount.
    function onTransfer(PoolId id, address token, address, address from, address, uint256) external view override onlyHook {
        Locker storage l = _lockers[id][from];
        uint256 locked = l.amount;
        if (locked == 0) return;
        uint256 unlockAt = uint256(l.day) * DAY;
        if (block.timestamp >= unlockAt) return;
        if (IERC20(token).balanceOf(from) < locked) revert LockedTokens(locked, unlockAt);
    }

    /// @notice Locks `amount` more of your balance (0 = only extend) until `unlockAt` (rounded up to 00:00
    ///         UTC; at least `minLock` from now, at most 365 days; never earlier than an active lock's).
    function lock(address token, uint256 amount, uint256 unlockAt) external nonReentrant {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _sync(id, p);
        Locker storage l = _lockers[id][msg.sender];
        _settle(id, p, l);
        uint256 old = l.amount; // active (an expired lock was cleared by _settle)
        if (unlockAt < block.timestamp + p.minLock || unlockAt > block.timestamp + MAX_LOCK) revert BadLock();
        uint256 day = (unlockAt + DAY - 1) / DAY;
        uint256 next = old + amount;
        if (day < l.day || next == 0 || (amount == 0 && day == l.day) || next > type(uint96).max) revert BadLock();
        if (IERC20(token).balanceOf(msg.sender) < next) revert BadLock();
        if (old > 0) {
            Batch storage ob = _batches[id][l.day];
            ob.expiring -= uint96(old);
            // an emptied day needs no snapshot: drop its bit so _advance never pays to expire it
            if (ob.expiring == 0 && l.day != day) _days[id][uint256(l.day) >> 8] &= ~(uint256(1) << (uint256(l.day) & 255));
            p.totalShares -= uint128(old);
        }
        _batches[id][day].expiring += uint96(next);
        _days[id][day >> 8] |= 1 << (day & 255);
        p.totalShares += uint128(next);
        (l.amount, l.day, l.ps0) = (uint96(next), uint32(day), uint160(p.perShare));
        if (day * DAY > p.maxUnlock) p.maxUnlock = uint64(day * DAY);
        emit Locked(token, msg.sender, next, day * DAY);
    }

    /// @notice Pays everything you earned, in the quote asset.
    function claim(address token) external nonReentrant returns (uint256 owed) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _sync(id, p);
        Locker storage l = _lockers[id][msg.sender];
        _settle(id, p, l);
        owed = l.owed;
        if (owed == 0) revert NothingOwed();
        l.owed = 0;
        p.paid += uint128(owed);
        _withdraw(p.quote, owed);
        cash[p.quote] -= owed;
        if (!_send(p.quote, msg.sender, owed)) revert SendFailed();
        emit Claimed(token, msg.sender, owed);
    }

    /// @notice Pays carry (fees that found no lockers) to the creator once nobody has been locked for
    ///         SWEEP_AFTER (180 days after the last lock's unlock time). Anyone.
    function sweepCarry(address token) external nonReentrant returns (uint256 amount) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _sync(id, p);
        amount = p.carry;
        if (amount == 0 || p.totalShares != 0 || block.timestamp < uint256(p.maxUnlock) + SWEEP_AFTER) revert NothingOwed();
        p.carry = 0;
        p.paid += uint128(amount);
        _withdraw(p.quote, amount);
        cash[p.quote] -= amount;
        if (!_send(p.quote, p.creator, amount)) revert SendFailed();
        emit CarrySwept(token, p.creator, amount);
    }

    /// @notice Confirms the last credit and expires every due unlock batch. Anyone (keeper after idle spells).
    function poke(address token) external {
        PoolId id = _poolIdOf(token);
        _sync(id, _pools[id]);
    }

    // ---------------------------------------------------------------- views

    /// @return quote       the earnings asset
    /// @return bps         share of every trade
    /// @return totalLocked locked and not expired (as of the last expiry pass)
    /// @return distributed folded into the index so far
    /// @return paid        claimed so far
    /// @return carry       waiting for lockers, plus the last trade's credit
    function stats(address token)
        external
        view
        returns (address quote, uint16 bps, uint256 totalLocked, uint256 distributed, uint256 paid, uint256 carry)
    {
        Pool storage p = _pools[_poolIdOf(token)];
        return (p.quote, p.bps, p.totalShares, p.distributed, p.paid, uint256(p.carry) + p.unverified);
    }

    /// @return amount   locked amount (0 = none or expired)
    /// @return unlockAt when it frees
    /// @return pending  earned and claimable (the very last trade joins on the next one)
    function lockOf(address token, address holder) external view returns (uint256 amount, uint256 unlockAt, uint256 pending) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        Locker storage l = _lockers[id][holder];
        amount = l.amount;
        unlockAt = uint256(l.day) * DAY;
        pending = l.owed;
        if (amount > 0) {
            uint256 end = l.day <= p.lastDay ? _batches[id][l.day].snap : p.perShare;
            pending += (amount * (end - l.ps0)) / MAG;
            if (block.timestamp >= unlockAt) amount = 0;
        }
    }

    // ---------------------------------------------------------------- internals

    function _poolIdOf(address token) internal view returns (PoolId id) {
        id = poolOf[token];
        if (!_pools[id].live || _pools[id].token != token) revert UnknownToken();
    }

    /// @dev Outside a callback: confirm the last credit (folds it), then expire every due batch.
    function _sync(PoolId id, Pool storage p) internal {
        _reconcile();
        _advance(id, p, type(uint256).max);
    }

    /// @dev Expires the unlock batches due by today (at most `maxSteps`), snapshotting the index for each.
    function _advance(PoolId id, Pool storage p, uint256 maxSteps) internal {
        uint256 today = block.timestamp / DAY;
        uint256 from = uint256(p.lastDay) + 1;
        if (from > today) return;
        uint256 ps = p.perShare;
        uint256 steps;
        for (uint256 w = from >> 8; w <= today >> 8; ++w) {
            uint256 bits = _days[id][w];
            if (bits == 0) continue;
            uint256 lo = w == from >> 8 ? from & 255 : 0;
            uint256 hi = w == today >> 8 ? today & 255 : 255;
            bits = (bits >> lo) << lo; // drop days before `from`
            if (hi < 255) bits &= (uint256(1) << (hi + 1)) - 1; // and after today
            while (bits != 0) {
                uint256 bit = _lowestBit(bits);
                bits &= bits - 1;
                uint256 day = (w << 8) | bit;
                Batch storage b = _batches[id][day];
                // Empty days (every lock on them was extended) hold nobody: skip them for free. Writing a snapshot
                // into an empty slot costs a fresh SSTORE, and a run of them could push a trade over the hook's
                // per-module gas budget (final audit M).
                if (b.expiring == 0) continue;
                if (steps == maxSteps) {
                    p.lastDay = uint64(day - 1);
                    return;
                }
                ++steps;
                p.totalShares -= b.expiring;
                b.snap = uint160(ps);
            }
        }
        p.lastDay = uint64(today);
    }

    /// @dev Moves a locker's earnings to `owed`; clears an expired lock.
    function _settle(PoolId id, Pool storage p, Locker storage l) internal {
        uint256 amount = l.amount;
        if (amount == 0) return;
        bool expired = l.day <= p.lastDay;
        uint256 end = expired ? _batches[id][l.day].snap : p.perShare;
        l.owed += uint128((amount * (end - l.ps0)) / MAG);
        if (expired) {
            (l.amount, l.day, l.ps0) = (0, 0, 0);
        } else {
            l.ps0 = uint160(end);
        }
    }

    function _fold(Pool storage p, uint256 amount) internal {
        uint256 total = amount + p.carry;
        uint256 shares = p.totalShares;
        if (shares < MIN_FOLD_SHARES) {
            p.carry = uint128(total);
            return;
        }
        uint256 next = p.perShare + (total * MAG) / shares;
        if (next > type(uint160).max) {
            p.carry = uint128(total); // unreachable in practice; never corrupt the index
            return;
        }
        p.carry = 0;
        p.perShare = next;
        p.distributed += uint128(total);
    }

    function _lowestBit(uint256 x) internal pure returns (uint256 n) {
        unchecked {
            x &= ~x + 1; // isolate the lowest set bit
        }
        if (x >= 1 << 128) (x, n) = (x >> 128, n + 128);
        if (x >= 1 << 64) (x, n) = (x >> 64, n + 64);
        if (x >= 1 << 32) (x, n) = (x >> 32, n + 32);
        if (x >= 1 << 16) (x, n) = (x >> 16, n + 16);
        if (x >= 1 << 8) (x, n) = (x >> 8, n + 8);
        if (x >= 1 << 4) (x, n) = (x >> 4, n + 4);
        if (x >= 1 << 2) (x, n) = (x >> 2, n + 2);
        if (x >= 1 << 1) n += 1;
    }

    /// @dev Makes sure `cash[quote]` covers `amount`, withdrawing this module's whole claim from the hook.
    function _withdraw(address quote, uint256 amount) internal {
        if (cash[quote] >= amount) return;
        uint256 c = AvaxHookV2(payable(hook)).claimable(address(this), Currency.wrap(quote));
        if (c == 0) return;
        uint256 a = accounted(quote);
        _spent(quote, c > a ? a : c);
        cash[quote] += c;
        AvaxHookV2(payable(hook)).claim(Currency.wrap(quote), address(this));
    }

    function _send(address quote, address to, uint256 amount) internal returns (bool ok) {
        if (quote == address(0)) {
            (ok,) = to.call{value: amount}("");
            return ok;
        }
        IERC20(quote).safeTransfer(to, amount);
        return true;
    }

    // LedgerModuleBase: earnings stay claimable even if the module is disabled.
    function _takeShare(PoolId id) internal view override returns (address, uint256) {
        return (_pools[id].quote, 0);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Pool storage p = _pools[id];
        return (p.quote, p.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Pool storage p = _pools[id];
        uint256 ok = p.unverified - shortfall;
        p.unverified = 0;
        if (ok > 0) _fold(p, ok);
    }
}
