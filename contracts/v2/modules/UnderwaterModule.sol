// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {HookLaunchpadV2} from "../HookLaunchpadV2.sol";
import {IAvaxHookV2View} from "./HookModuleBase.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title UnderwaterModule
/// @notice `bps` of every trade's quote amount (buys: from the input, sells: from the output; curve and pool,
///         every route) fills a pot that partly refunds holders who are below what they paid ("underwater").
///   - Cost basis (quote): a buy whose buyer is known (every curve buy; pool buys through the AvaxHook router)
///     adds what the buyer spent, but never more than the tokens' worth at the reference price: the lower of
///     the time-weighted average over at least the last `interval` and the price this second opened at. Buying
///     into a pump (someone else's, or your own other wallet's) therefore books the fair value, not a loss. Aggregator / direct PoolManager buys add no basis (the buyer is unknown), so
///     those tokens never count as underwater. Every outgoing move (sell or send) lowers the sender's basis
///     in proportion (basis × amount / balance before), rounded in the pot's favour; tokens received from
///     another wallet come with zero basis, so moving tokens around never creates a claim.
///   - Rounds: the keeper (set by the owner, the Safe) calls `distribute(token, wallets)` at most once per
///     `interval` per pool, with up to MAX_BATCH wallets in ascending address order. The contract itself
///     computes every wallet's gap = basis − balance × price and pays nobody who isn't underwater:
///       - the round spends at most `roundBps` of the pot, split by gap;
///       - a wallet gets at most `maxGapShareBps` of its gap per round, and over its life at most half of
///         all the basis it ever added (LIFETIME_BPS);
///       - a wallet whose last counted buy is less than `interval` old, or that holds less than `minHoldBps`
///         of the supply, is skipped.
///     What a wallet is paid also comes off its basis, so payouts stop well before break-even. Paid as a claim
///     in the hook (`transferClaim`), withdrawn with `AvaxHookV2.claim`.
///   - Price: max(spot, time-weighted average over at least the last `interval`). The average comes from an
///     O(1) cumulative-price accumulator updated by every trade (Uniswap-oracle style, curve and pool), so a
///     dump just before a round does not create gaps; the price has to stay down for an interval.
///   - Honest limits: a loss-refund pot can still be gamed by wallets that trade against each other (one pumps,
///     one buys high, the first dumps) when the pot is worth more than the fees they pay. The per-round and
///     lifetime caps, the TWAP and the interval only make that slow and usually unprofitable; they don't make
///     it impossible. The keeper chooses whom to list (and so how a round is split), but the contract checks
///     every gap and limit, so it can never pay a wallet that isn't underwater or more than the caps.
///   - Flash moves: tokens moved into a wallet raise its value (no basis) and tokens moved out cut its basis in
///     proportion, so moving tokens around a payout can only shrink a gap. Borrowed tokens can only help pass
///     the `minHoldBps` dust filter.
///   - Not identity-neutral: transfer rule and per-wallet payouts. Never refuses a trade or transfer.
///   - Kill switch: if the registry disables the module, transfers stop reaching it and cost bases would go
///     stale, so `distribute` is refused and `rescue` pays the pot to the creator (as the other pot modules).
contract UnderwaterModule is LedgerModuleBase, Ownable2Step {
    struct Config {
        uint16 bps; // of each trade's quote amount: 0.01% .. 5%
        uint16 minHoldBps; // a wallet must hold this share of the supply to be paid: 0 .. 1%
        uint32 interval; // seconds between rounds, buy age and TWAP window: 5 min .. 30 days
        uint16 roundBps; // share of the pot one round may spend: 5% .. 100%
        uint16 maxGapShareBps; // share of a wallet's gap one round may pay: 0.01% .. 50%
    }

    struct Pool {
        // slot 0
        address token;
        uint16 bps;
        uint16 minHoldBps;
        uint32 interval;
        bool live;
        // slot 1
        address quote;
        uint16 roundBps;
        uint16 maxGapShareBps;
        uint48 lastRound; // last distribute
        // slot 2: price accumulator (Σ marketCap × seconds) and its last update
        uint160 cum;
        uint48 cumAt;
        // slot 3: newest checkpoint (taken at most every `interval`)
        uint160 ckCum;
        uint48 ckAt;
        // slot 4: the checkpoint before it
        uint160 prevCum;
        uint48 prevAt;
        // slot 5
        uint128 pot; // this pool's share of the module's claim
        uint128 unverified; // credits announced to the hook, not yet checked against its books
        // slot 6
        uint128 totalPaid;
        uint64 rounds;
        // slot 7
        uint128 openMcap; // market cap before the first trade of the current second
    }

    struct Wallet {
        uint128 basis; // quote paid for the tokens held (proportionally reduced by every outgoing move)
        uint64 lastBuyAt; // last buy that added basis
        uint64 lastPaidAt;
        uint128 added; // all basis ever added
        uint128 paid; // all ever paid
    }

    uint16 public constant MAX_BPS = 500;
    uint16 public constant MAX_HOLD_BPS = 100;
    uint32 public constant MIN_INTERVAL = 5 minutes;
    uint32 public constant MAX_INTERVAL = 30 days;
    uint16 public constant MIN_ROUND_BPS = 500;
    uint16 public constant MAX_GAP_SHARE_BPS = 5_000;
    /// @notice A wallet is paid at most this share of all the basis it ever added.
    uint16 public constant LIFETIME_BPS = 5_000;
    uint256 public constant MAX_BATCH = 100;

    address internal immutable launchpad;
    address public keeper;

    mapping(PoolId => Pool) internal _pools;
    mapping(address => PoolId) public poolOf;
    mapping(PoolId => mapping(address => Wallet)) internal _wallets;

    event Registered(address indexed token, PoolId id, address quote, uint16 bps);
    event KeeperSet(address keeper);
    event UnderwaterPaid(address indexed token, address indexed wallet, uint256 amount, uint256 gapBefore);
    event Distributed(address indexed token, address indexed caller, uint256 wallets, uint256 paid, uint256 marketCap);

    error UnknownToken();
    error BatchTooLarge();
    error NotSorted();
    error ModuleDisabled();
    error NotKeeper();
    error TooSoon(uint256 nextAt);

    constructor(address _hook, address _owner) LedgerModuleBase(_hook) Ownable(_owner) {
        launchpad = IAvaxHookV2View(_hook).launchpad();
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.bps == 0 || c.bps > MAX_BPS || c.minHoldBps > MAX_HOLD_BPS) revert BadConfig();
        if (c.interval < MIN_INTERVAL || c.interval > MAX_INTERVAL) revert BadConfig();
        if (c.roundBps < MIN_ROUND_BPS || c.roundBps > BPS) revert BadConfig();
        if (c.maxGapShareBps == 0 || c.maxGapShareBps > MAX_GAP_SHARE_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config) external override onlyHook {
        Pool storage p = _pools[id];
        if (p.live) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (p.token, p.bps, p.minHoldBps, p.interval, p.live) = (token, c.bps, c.minHoldBps, c.interval, true);
        (p.quote, p.roundBps, p.maxGapShareBps) = (quote, c.roundBps, c.maxGapShareBps);
        uint48 nowTs = uint48(block.timestamp);
        (p.cumAt, p.ckAt, p.prevAt) = (nowTs, nowTs, nowTs); // warms the accumulator slots
        p.rounds = 1;
        poolOf[token] = id;
        _seed(quote);
        emit Registered(token, id, quote, c.bps);
    }

    // ---------------------------------------------------------------- trades

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        Pool storage p = _pools[ctx.poolId];
        _observe(p, _marketCapQuote(p.token, p.quote, ctx.sqrtPriceX96));
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _accrue(ctx.poolId, ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return _accrue(ctx.poolId, ctx.amountOut);
        if (ctx.trader != address(0)) {
            Pool storage p = _pools[ctx.poolId];
            if (!_plumbing(p.token, ctx.trader)) {
                // Basis = what was paid, but never more than the tokens' worth at the reference price (the
                // lower of the interval average and this second's opening price): buying into a pump books no gap.
                uint256 fair = Math.mulDiv(ctx.amountOut, _buyPrice(p), TOTAL_SUPPLY);
                uint256 add = Math.min(ctx.amountIn, fair);
                Wallet storage w = _wallets[ctx.poolId][ctx.trader];
                uint256 b = uint256(w.basis) + add;
                w.basis = b > type(uint128).max ? type(uint128).max : uint128(b);
                b = uint256(w.added) + add;
                w.added = b > type(uint128).max ? type(uint128).max : uint128(b);
                w.lastBuyAt = uint64(block.timestamp);
            }
        }
        return new Credit[](0);
    }

    /// @dev Reference market cap for valuing a buy: min(TWAP over at least the last interval, the price before
    ///      this second's first trade); just the opening price while there is no history yet.
    function _buyPrice(Pool storage p) internal view returns (uint256) {
        uint256 nowTs = block.timestamp;
        uint256 open = p.openMcap;
        (uint256 c0, uint256 t0) = nowTs >= uint256(p.ckAt) + p.interval ? (p.ckCum, p.ckAt) : (p.prevCum, p.prevAt);
        if (nowTs <= t0 || p.cum < c0) return open;
        return Math.min((uint256(p.cum) - c0) / (nowTs - t0), open);
    }

    function _accrue(PoolId id, uint256 amount) internal returns (Credit[] memory) {
        _reconcile();
        Pool storage p = _pools[id];
        uint256 share = (amount * p.bps) / BPS;
        if (share == 0) return new Credit[](0);
        p.pot += uint128(share);
        p.unverified += uint128(share);
        _expect(id, p.quote, share);
        return _one(address(this), share);
    }

    /// @dev Adds the price that held since the last trade (the pre-trade price of this one) to the accumulator,
    ///      and rolls the checkpoints at most once per interval.
    function _observe(Pool storage p, uint256 mcapBefore) internal {
        uint256 nowTs = block.timestamp;
        uint256 dt = nowTs - p.cumAt;
        if (dt == 0 && p.openMcap != 0) return;
        p.openMcap = uint128(Math.min(mcapBefore, type(uint128).max)); // the price this second opened at
        if (dt == 0) return;
        uint256 c = uint256(p.cum) + mcapBefore * dt;
        if (c > type(uint160).max) c = type(uint160).max; // saturates (unreachable for real market caps)
        (p.cum, p.cumAt) = (uint160(c), uint48(nowTs));
        if (nowTs >= uint256(p.ckAt) + p.interval) {
            (p.prevCum, p.prevAt) = (p.ckCum, p.ckAt);
            (p.ckCum, p.ckAt) = (uint160(c), uint48(nowTs));
        }
    }

    /// @dev Outgoing moves lower the sender's basis in proportion; incoming wallet-to-wallet moves add none.
    function onTransfer(PoolId id, address token, address, address from, address, uint256 amount) external override onlyHook {
        if (amount == 0 || _plumbing(token, from)) return;
        Wallet storage w = _wallets[id][from];
        uint256 basis = w.basis;
        if (basis == 0) return;
        uint256 before = IERC20(token).balanceOf(from) + amount;
        uint256 cut = Math.mulDiv(basis, amount, before, Math.Rounding.Ceil);
        w.basis = uint128(cut >= basis ? 0 : basis - cut);
    }

    // ---------------------------------------------------------------- payouts

    /// @notice One round per `interval`: pays the listed underwater wallets (ascending addresses, at most
    ///         MAX_BATCH) within the round budget and the per-wallet caps. Keeper (or owner) only.
    function distribute(address token, address[] calldata wallets) external returns (uint256 paid, uint256 count) {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        if (wallets.length > MAX_BATCH) revert BatchTooLarge();
        // Disabled: transfers no longer reach the module, so cost bases would go stale. Only `rescue` remains.
        if (AvaxHookV2(payable(hook)).disabled(address(this))) revert ModuleDisabled();
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        uint256 next = uint256(p.lastRound) + p.interval;
        if (p.lastRound != 0 && block.timestamp < next) revert TooSoon(next);
        p.lastRound = uint48(block.timestamp);
        _reconcile();
        uint256 mcap = _priceMcap(id, p);
        uint256 budget = (uint256(p.pot) * p.roundBps) / BPS;
        uint256[] memory gaps = new uint256[](wallets.length);
        uint256 sum;
        address prev;
        for (uint256 i; i < wallets.length; ++i) {
            address a = wallets[i];
            if (a <= prev) revert NotSorted();
            prev = a;
            uint256 g = _gap(id, p, a, mcap);
            gaps[i] = g;
            sum += g;
        }
        if (sum > 0 && budget > 0) {
            for (uint256 i; i < wallets.length; ++i) {
                uint256 g = gaps[i];
                if (g == 0) continue;
                Wallet storage w = _wallets[id][wallets[i]];
                uint256 pay = Math.min(Math.mulDiv(budget, g, sum), _cap(p, w, g));
                if (pay == 0) continue;
                w.basis -= uint128(pay); // pay <= gap <= basis
                w.paid += uint128(pay);
                w.lastPaidAt = uint64(block.timestamp);
                paid += pay;
                ++count;
                _payClaim(p.quote, wallets[i], pay);
                emit UnderwaterPaid(token, wallets[i], pay, g);
            }
            p.pot -= uint128(paid);
            p.totalPaid += uint128(paid);
        }
        p.rounds += 1;
        emit Distributed(token, msg.sender, count, paid, mcap);
    }

    // ---------------------------------------------------------------- views

    /// @return pot          the confirmed pot
    /// @return budget       what the next round may spend (roundBps of the pot)
    /// @return totalPaid    paid to underwater holders so far
    /// @return marketCap    the 1B market cap in quote units the next round prices wallets at
    /// @return nextRoundAt  earliest time of the next round
    function stats(address token)
        external
        view
        returns (uint256 pot, uint256 budget, uint256 totalPaid, uint256 marketCap, uint256 nextRoundAt)
    {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        pot = p.pot - p.unverified;
        nextRoundAt = p.lastRound == 0 ? 0 : uint256(p.lastRound) + p.interval;
        return (pot, (pot * p.roundBps) / BPS, p.totalPaid, _priceMcap(id, p), nextRoundAt);
    }

    /// @return basis      quote the wallet paid for what it holds (as tracked)
    /// @return value      its balance at the price the next round uses
    /// @return gap        how far it is underwater and eligible now (0 if not)
    /// @return maxPay     the most the next round may pay it (before the round's budget split)
    /// @return eligibleAt when its buy cool-down ends
    function position(address token, address wallet)
        external
        view
        returns (uint256 basis, uint256 value, uint256 gap, uint256 maxPay, uint256 eligibleAt)
    {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        Wallet storage w = _wallets[id][wallet];
        uint256 mcap = _priceMcap(id, p);
        basis = w.basis;
        value = Math.mulDiv(mcap, IERC20(token).balanceOf(wallet), TOTAL_SUPPLY);
        gap = _gap(id, p, wallet, mcap);
        maxPay = _cap(p, w, gap);
        eligibleAt = uint256(w.lastBuyAt) + p.interval;
    }

    /// @notice Time-weighted average 1B market cap (quote units) over at least the last `interval`.
    function twapMarketCap(address token) external view returns (uint256) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        return _twap(p, _spotMcap(id, p));
    }

    // ---------------------------------------------------------------- internals

    function _cap(Pool storage p, Wallet storage w, uint256 gap) internal view returns (uint256) {
        uint256 life = (uint256(w.added) * LIFETIME_BPS) / BPS;
        uint256 left = life > w.paid ? life - w.paid : 0;
        return Math.min((gap * p.maxGapShareBps) / BPS, left);
    }

    function _gap(PoolId id, Pool storage p, address a, uint256 mcap) internal view returns (uint256) {
        if (_plumbing(p.token, a)) return 0;
        Wallet storage w = _wallets[id][a];
        uint256 basis = w.basis;
        if (basis == 0) return 0;
        if (block.timestamp < uint256(w.lastBuyAt) + p.interval) return 0; // only buys older than an interval
        uint256 bal = IERC20(p.token).balanceOf(a);
        if (bal == 0 || bal < (TOTAL_SUPPLY * p.minHoldBps) / BPS) return 0;
        uint256 value = Math.mulDiv(mcap, bal, TOTAL_SUPPLY, Math.Rounding.Ceil);
        return basis > value ? basis - value : 0;
    }

    /// @dev Market cap (1B supply) in quote at max(spot, TWAP over at least the last interval).
    function _priceMcap(PoolId id, Pool storage p) internal view returns (uint256) {
        uint256 spot = _spotMcap(id, p);
        return Math.max(spot, _twap(p, spot));
    }

    function _twap(Pool storage p, uint256 spot) internal view returns (uint256) {
        uint256 nowTs = block.timestamp;
        uint256 cumNow = uint256(p.cum) + spot * (nowTs - p.cumAt);
        // the newest checkpoint that is at least an interval old (else the older one, else launch)
        (uint256 c0, uint256 t0) = nowTs >= uint256(p.ckAt) + p.interval ? (p.ckCum, p.ckAt) : (p.prevCum, p.prevAt);
        if (nowTs <= t0 || cumNow < c0) return spot;
        return (cumNow - c0) / (nowTs - t0);
    }

    function _spotMcap(PoolId id, Pool storage p) internal view returns (uint256) {
        address token = p.token;
        address quote = p.quote;
        uint160 spot;
        if (AvaxHookV2(payable(hook)).isOpen(id)) {
            spot = _sqrtPrice(id);
        } else {
            HookLaunchpadV2 lp = HookLaunchpadV2(payable(launchpad));
            HookLaunchpadV2.Launch memory l = lp.getLaunch(token);
            (uint256 x, uint256 y) = l.complete
                ? (uint256(l.virtualQuote) + l.target, uint256(l.virtualTokens) - lp.CURVE_SUPPLY())
                : (uint256(l.virtualQuote) + l.reserve, uint256(l.virtualTokens) - l.tokensSold);
            spot = lp.curveSqrtPrice(quote, token, x, y);
        }
        return _marketCapQuote(token, quote, spot);
    }

    function _plumbing(address token, address who) internal view returns (bool) {
        return who == address(poolManager) || who == launchpad || who == hook || who == ModuleCaps.BURN
            || who == address(this) || who == token || who == address(0);
    }

    function _poolIdOf(address token) internal view returns (PoolId id) {
        id = poolOf[token];
        if (!_pools[id].live || _pools[id].token != token) revert UnknownToken();
    }

    function _takeShare(PoolId id) internal override returns (address, uint256 amount) {
        Pool storage p = _pools[id];
        amount = p.pot;
        p.pot = 0;
        return (p.quote, amount);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Pool storage p = _pools[id];
        return (p.quote, p.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Pool storage p = _pools[id];
        p.pot = shortfall > p.pot ? 0 : p.pot - uint128(shortfall);
        p.unverified = 0;
    }
}
