// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {IAvaxHookV2View, IQuotePrices} from "./HookModuleBase.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title HolderDividendsModule
/// @notice `bps` of every trade's quote amount (from what buyers pay, from what sellers receive; curve and pool,
///         every route) is shared among the token's holders, pro-rata to their balance ("dividend per share").
///   - Accrual: the share is credited to this module in the hook like a pot, and folded into the per-share
///     index once the hook's books confirm it (LedgerModuleBase), at the holders' recorded shares of that
///     moment. Every share change (onTransfer, claim, distribute) folds the pending credit FIRST, so a credit
///     is always folded at the shares from before any later balance change: nobody can borrow tokens (a
///     PoolManager `take`, an LP removal, a flash loan elsewhere), fold a previous trade's dividend while
///     holding them and give them back. The one credit that can't be folded early is the one of the swap
///     whose module callback is still running (the hook hasn't booked it yet); it folds at the first share
///     change after the hook books it — for a buy the delivery of the bought tokens (before the buyer's
///     shares grow), for a sell typically the seller's tokens reaching the pool (the seller still counted).
///     A trader who first borrows tokens inside the same unlock can thus recapture part of the dividend of
///     their OWN trade (never anyone else's).
///   - Balances: every transfer re-reads both sides' real balances (onTransfer), so a missed call (sells are
///     isolated) heals on the next move, payout or claim. The PoolManager, the launchpad, the hook, 0x…dEaD,
///     the token and this module never hold shares: dividends go to people, not to the pool or the curve.
///   - Payout: anyone (the AvaxHook keeper) calls `distribute(token, holders)`, which pays up to MAX_BATCH
///     holders their dividends straight to their wallets in one transaction. The caller's gas is taken from
///     the amounts: `PAY_GAS` per paid holder plus an equal share of the transaction's own `BATCH_GAS`, at the
///     current gas price (capped at twice the base fee), converted to the quote through the QuoteRegistry.
///     Holders owed less than MIN_PAYOUT_FEES times that fee wait for a later round. A send that fails (a contract that refuses AVAX, a blocklisted address) is
///     skipped and stays owed. Holders can always `claim` their own, with no fee.
///   - Unreachable dividends: once a `distribute` send to a holder failed (PayFailed) and RECYCLE_AFTER
///     (90 days) passed since that first failure without a later successful payout or claim, anyone can
///     `recycle` what they are owed back into the index for every holder. A holder whose payout never
///     failed (a passive holder below the keeper's minimum) is never recycled.
///   - Fixed forever at launch. Not identity-neutral (transfer rule): no one-transaction zap.
///   - Kill switch: if the registry disables the module the hook stops calling it; dividends already
///     accrued stay payable through `distribute` and `claim` (so `rescue` has nothing to move).
contract HolderDividendsModule is LedgerModuleBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Config {
        uint16 bps; // of each trade's quote amount: 0.5% .. 10%
    }

    struct Pool {
        address token;
        uint16 bps;
        bool live;
        address quote;
        uint128 unverified; // credits announced to the hook, not yet checked against its books
        uint256 totalShares;
        uint256 perShare; // magnified (MAG) cumulative dividend per share
        uint256 carry; // confirmed but not yet in the index (no holders yet)
        uint256 distributed; // folded into the index
        uint256 paid; // paid out (pushed, claimed or recycled back)
    }

    struct Stats {
        address quote;
        uint16 bps;
        uint256 totalShares;
        uint256 distributed;
        uint256 paid;
        uint256 undistributed;
    }

    uint16 public constant MIN_BPS = 50;
    uint16 public constant MAX_BPS = 1_000;
    uint256 public constant MAX_BATCH = 1_000;
    /// @notice Gas charged per paid holder (the send, the bookkeeping and the event, with headroom).
    uint256 public constant PAY_GAS = 40_000;
    /// @notice A batch's own gas (the transaction, withdrawing from the hook), shared by the holders it pays.
    uint256 public constant BATCH_GAS = 180_000;
    /// @notice A holder is paid once owed at least this many keeper fees (the fee stays <= 10%).
    uint256 public constant MIN_PAYOUT_FEES = 10;
    /// @notice Gas a holder's wallet gets for receiving AVAX (enough for a Safe; a refusing wallet just waits).
    uint256 public constant SEND_GAS = 30_000;
    /// @dev Gas a capped send must really have (63/64 rule + the value transfer), so a caller can't starve a
    ///      holder's wallet to fake a failed payout (which starts the recycle clock).
    uint256 internal constant SEND_MIN_GAS = (SEND_GAS * 64) / 63 + 15_000;
    uint256 public constant RECYCLE_AFTER = 90 days;
    uint256 internal constant MAG = 2 ** 128;
    /// @dev Credits wait in `carry` until holders own at least one whole token, so the per-share index can't
    ///      jump by a dust denominator (and overflow later, which would block transfers).
    uint256 internal constant MIN_FOLD_SHARES = 1 ether;

    address internal immutable launchpad;

    mapping(PoolId => Pool) internal _pools;
    mapping(address => PoolId) public poolOf;
    mapping(PoolId => mapping(address => uint256)) internal _shares;
    mapping(PoolId => mapping(address => int256)) internal _corrections;
    mapping(PoolId => mapping(address => uint256)) internal _withdrawn;
    mapping(PoolId => mapping(address => uint256)) public lastActive;
    /// @notice When a `distribute` send to the holder first failed since their last successful payout or
    ///         claim (0: none). Recycling counts RECYCLE_AFTER from here.
    mapping(PoolId => mapping(address => uint256)) public failedAt;
    /// @notice Quote this module holds itself (withdrawn from the hook, not yet paid), per quote asset.
    mapping(address => uint256) public cash;

    event DividendPaid(address indexed token, address indexed holder, uint256 amount);
    event DividendClaimed(address indexed token, address indexed holder, uint256 amount);
    event PayFailed(address indexed token, address indexed holder, uint256 amount);
    event Distributed(address indexed token, address indexed keeper, uint256 recipients, uint256 paid, uint256 keeperFee);
    event Recycled(address indexed token, address indexed holder, uint256 amount);
    /// @notice A launch picked this module (lets the keeper find its tokens without decoding every pool).
    event Registered(address indexed token, PoolId id, address quote, uint16 bps);

    error UnknownToken();
    error BatchTooLarge();
    error NothingOwed();
    error SendFailed();
    error NeedMoreGas();

    constructor(address _hook) LedgerModuleBase(_hook) {
        launchpad = IAvaxHookV2View(_hook).launchpad();
    }

    receive() external payable {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.bps < MIN_BPS || c.bps > MAX_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config) external override onlyHook {
        Pool storage p = _pools[id];
        if (p.live) revert AlreadyRegistered();
        p.token = token;
        p.bps = abi.decode(config, (Config)).bps;
        p.quote = quote;
        p.live = true;
        poolOf[token] = id;
        _seed(quote);
        emit Registered(token, id, quote, p.bps);
    }

    // ---------------------------------------------------------------- accrual

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _accrue(ctx.poolId, ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _accrue(ctx.poolId, ctx.amountOut);
    }

    function _accrue(PoolId id, uint256 amount) internal returns (Credit[] memory) {
        _reconcile();
        Pool storage p = _pools[id];
        uint256 share = (amount * p.bps) / BPS;
        if (share == 0) return new Credit[](0);
        p.unverified += uint128(share);
        _expect(id, p.quote, share);
        return _one(address(this), share);
    }

    // ---------------------------------------------------------------- balances

    function onTransfer(PoolId id, address, address, address from, address to, uint256) external override onlyHook {
        // Fold the pending credit at the shares from before this move (the token already moved, the shares
        // not yet): a balance borrowed for a moment never earns an earlier trade's dividend.
        _reconcile();
        _sync(id, from);
        if (to != from) _sync(id, to);
    }

    /// @dev Sets `who`'s shares to its real balance (0 for the pool, the curve and other plumbing).
    function _sync(PoolId id, address who) internal {
        Pool storage p = _pools[id];
        uint256 next = _excluded(p.token, who) ? 0 : IERC20(p.token).balanceOf(who);
        uint256 prev = _shares[id][who];
        if (next == prev) return;
        uint256 ps = p.perShare;
        if (next > prev) {
            uint256 d = next - prev;
            _corrections[id][who] -= int256(ps * d);
            p.totalShares += d;
        } else {
            uint256 d = prev - next;
            _corrections[id][who] += int256(ps * d);
            p.totalShares -= d;
        }
        _shares[id][who] = next;
        lastActive[id][who] = block.timestamp;
    }

    function _excluded(address token, address who) internal view returns (bool) {
        return who == address(poolManager) || who == hook || who == ModuleCaps.BURN || who == address(this) || who == token
            || who == address(0) || who == launchpad;
    }

    // ---------------------------------------------------------------- payouts

    /// @notice Pays up to MAX_BATCH holders their dividends to their wallets in one transaction. Anyone; the
    ///         caller gets a flat per-holder gas fee out of the amounts (see PAY_GAS). Holders owed less than
    ///         the minimum payout, and sends that fail, are skipped and stay owed.
    function distribute(address token, address[] calldata holders) external nonReentrant returns (uint256 paid, uint256 count) {
        if (holders.length > MAX_BATCH) revert BatchTooLarge();
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _settle(p.quote);
        uint256 gasPrice = Math.min(tx.gasprice, 2 * block.basefee);
        uint256 perPay = _gasInQuote(p.quote, PAY_GAS * gasPrice);
        // The batch's own gas is shared by the holders it will pay (counted at the per-holder minimum).
        uint256 eligible;
        for (uint256 i; i < holders.length; ++i) {
            _sync(id, holders[i]);
            uint256 o = _owed(id, holders[i]);
            if (o > 0 && o >= perPay * MIN_PAYOUT_FEES) ++eligible;
        }
        if (eligible == 0) {
            emit Distributed(token, msg.sender, 0, 0, 0);
            return (0, 0);
        }
        uint256 fee = perPay + _gasInQuote(p.quote, BATCH_GAS * gasPrice) / eligible;
        uint256 minPayout = fee == 0 ? 1 : fee * MIN_PAYOUT_FEES;
        uint256 fees;
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            uint256 owed = _owed(id, h); // fresh: a holder listed twice is paid once
            if (owed == 0 || owed < minPayout) continue;
            _withdrawn[id][h] += owed;
            if (gasleft() < SEND_MIN_GAS) revert NeedMoreGas();
            if (!_send(p.quote, h, owed - fee, true)) {
                _withdrawn[id][h] -= owed;
                if (failedAt[id][h] == 0) failedAt[id][h] = block.timestamp;
                emit PayFailed(token, h, owed);
                continue;
            }
            lastActive[id][h] = block.timestamp;
            if (failedAt[id][h] != 0) failedAt[id][h] = 0;
            paid += owed - fee;
            fees += fee;
            ++count;
            emit DividendPaid(token, h, owed - fee);
        }
        p.paid += paid + fees;
        cash[p.quote] -= paid + fees;
        if (fees > 0 && !_send(p.quote, msg.sender, fees, false)) revert SendFailed();
        emit Distributed(token, msg.sender, count, paid, fees);
    }

    /// @notice Pays the caller's own dividends, in full.
    function claim(address token) external nonReentrant returns (uint256 owed) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _settle(p.quote);
        _sync(id, msg.sender);
        owed = _owed(id, msg.sender);
        if (owed == 0) revert NothingOwed();
        _withdrawn[id][msg.sender] += owed;
        lastActive[id][msg.sender] = block.timestamp;
        if (failedAt[id][msg.sender] != 0) failedAt[id][msg.sender] = 0;
        p.paid += owed;
        cash[p.quote] -= owed;
        if (!_send(p.quote, msg.sender, owed, false)) revert SendFailed();
        emit DividendClaimed(token, msg.sender, owed);
    }

    /// @notice Shares the dividends of holders who can't receive (a `distribute` send to them failed at least
    ///         RECYCLE_AFTER ago, with no successful payout or claim since) among every holder again. Anyone.
    ///         Holders whose payout never failed are skipped.
    function recycle(address token, address[] calldata holders) external nonReentrant {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _reconcile();
        uint256 back;
        for (uint256 i; i < holders.length; ++i) {
            address h = holders[i];
            uint256 f = failedAt[id][h];
            if (f == 0 || block.timestamp < f + RECYCLE_AFTER) continue;
            uint256 owed = _owed(id, h);
            if (owed == 0) continue;
            _withdrawn[id][h] += owed;
            failedAt[id][h] = 0;
            lastActive[id][h] = block.timestamp;
            back += owed;
            emit Recycled(token, h, owed);
        }
        if (back == 0) return;
        // Recycled money was already counted as distributed; it re-enters the index without counting twice.
        p.distributed -= back;
        _fold(p, back);
    }

    // ---------------------------------------------------------------- views

    function stats(address token) external view returns (Stats memory s) {
        Pool storage p = _pools[_poolIdOf(token)];
        return Stats(p.quote, p.bps, p.totalShares, p.distributed, p.paid, p.carry + p.unverified);
    }

    /// @notice Dividends `holder` can be paid now (credits of the very last trades join on the next one).
    function pending(address token, address holder) external view returns (uint256) {
        return _owed(_poolIdOf(token), holder);
    }

    function sharesOf(address token, address holder) external view returns (uint256) {
        return _shares[_poolIdOf(token)][holder];
    }

    /// @notice The keeper's fee at the base fee, in quote units: `perRecipient` for each paid holder plus
    ///         `perBatch` shared by the holders a batch pays; `minPayout` is the smallest payout when a batch
    ///         pays a single holder (more holders, a lower one).
    function keeperFee(address token) external view returns (uint256 perRecipient, uint256 perBatch, uint256 minPayout) {
        address quote = _pools[_poolIdOf(token)].quote;
        perRecipient = _gasInQuote(quote, PAY_GAS * block.basefee);
        perBatch = _gasInQuote(quote, BATCH_GAS * block.basefee);
        minPayout = perRecipient + perBatch == 0 ? 1 : (perRecipient + perBatch) * MIN_PAYOUT_FEES;
    }

    // ---------------------------------------------------------------- internals

    function _poolIdOf(address token) internal view returns (PoolId id) {
        id = poolOf[token];
        if (!_pools[id].live || _pools[id].token != token) revert UnknownToken();
    }

    function _owed(PoolId id, address h) internal view returns (uint256) {
        int256 acc = int256(_pools[id].perShare * _shares[id][h]) + _corrections[id][h];
        uint256 total = acc <= 0 ? 0 : uint256(acc) / MAG;
        uint256 w = _withdrawn[id][h];
        return total > w ? total - w : 0;
    }

    /// @dev Confirmed credits enter the index at today's holders; until there are any they wait in `carry`.
    function _fold(Pool storage p, uint256 amount) internal {
        uint256 total = amount + p.carry;
        if (p.totalShares < MIN_FOLD_SHARES) {
            p.carry = total;
            return;
        }
        p.carry = 0;
        p.perShare += (total * MAG) / p.totalShares;
        p.distributed += total;
    }

    /// @dev Verifies the last credit, then moves this module's whole claim in `quote` out of the hook into cash.
    function _settle(address quote) internal {
        _reconcile();
        uint256 c = AvaxHookV2(payable(hook)).claimable(address(this), Currency.wrap(quote));
        if (c == 0) return;
        uint256 a = accounted(quote);
        _spent(quote, c > a ? a : c);
        cash[quote] += c;
        AvaxHookV2(payable(hook)).claim(Currency.wrap(quote), address(this));
    }

    /// @dev An amount of AVAX (wei) in quote units.
    function _gasInQuote(address quote, uint256 wei_) internal view returns (uint256 fee) {
        if (quote == address(0)) {
            fee = wei_;
        } else {
            // AVAX -> quote at the registry's prices; no price, no fee (holders never pay for a missing feed).
            IQuotePrices r = IQuotePrices(IAvaxHookV2View(hook).quoteRegistry());
            try r.usdPrice(address(0)) returns (uint256 avaxUsd) {
                try r.usdPrice(quote) returns (uint256 quoteUsd) {
                    fee = quoteUsd == 0 ? 0 : Math.mulDiv(wei_ * avaxUsd, 10 ** IERC20Metadata(quote).decimals(), quoteUsd * 1e18);
                } catch {}
            } catch {}
        }
    }

    /// @dev Sends quote from cash. `capped`: a holder's wallet gets SEND_GAS and may fail without reverting.
    function _send(address quote, address to, uint256 amount, bool capped) internal returns (bool ok) {
        if (amount == 0) return true;
        if (quote == address(0)) {
            (ok,) = capped ? to.call{value: amount, gas: SEND_GAS}("") : to.call{value: amount}("");
            return ok;
        }
        bytes memory ret;
        (ok, ret) = quote.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    // LedgerModuleBase: the pool's money stays payable through distribute/claim even if the module is
    // disabled, so `rescue` has nothing to move.
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
