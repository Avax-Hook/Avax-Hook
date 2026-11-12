// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IProtocolRecipient {
    function protocolRecipient() external view returns (address);
}

/// @title AvaxHook
/// @notice One Uniswap v4 hook shared by every AvaxHook pool on Avalanche C-Chain. Each pool
///         carries its own frozen set of hooks, chosen by the creator at launch.
///
///   Protection
///   - Anti-snipe     guard window after open: cumulative per-block buy cap, snipe tax on buys,
///                    exact-output buys refused, outside liquidity refused.
///   - Whale guard    per-transaction buy cap in AVAX for a window after open.
///   - Dump guard     per-transaction sell cap, as a share of total supply, for a window.
///   - MEV shield     swaps paying more than a priority-fee cap revert for a window.
///   - Sell tax decay an extra LP fee on sells that falls linearly to zero over a window.
///   Fees
///   - Dynamic fee    LP fee = base + surge, surge scales with trade size vs in-range depth.
///   - Volatility fee extra LP fee proportional to how far price already moved this block.
///   - Creator fee    a share of AVAX on every buy and sell, paid to the creator.
///   - Referral       a share of buys paid to the buyer's referrer. The first referrer the router
///                    passes in for a buyer is bound for good; later ones are ignored.
///   Rewards and burn
///   - Auto burn      a share of every buy's token output is sent to 0xdead.
///   - Buyback & burn a share of AVAX from sells is saved and spent buying the token back
///                    and burning it; the keeper triggers a capped buyback whose price is bounded
///                    by a reference price at least `REF_MIN_AGE_BLOCKS` old.
///   - LP rewards     a share of every buy's AVAX is donated to in-range liquidity.
///   - Nth-buy pot    a share of buys fills a pot; every Nth qualifying buy takes it.
///   - Last-buyer pot a share of buys fills a pot; when no qualifying buy lands for a set time,
///                    the last qualifying buyer takes it. A pot with no leader goes to the creator
///                    after `TIMER_ORPHAN_SECONDS` without a qualifying buy.
///
/// A pool pairs the launched token with its quote asset (native AVAX, USDC or a tokenized stock);
/// either may be currency0. Cuts are always taken in the quote asset, held as ERC-6909 claims in
/// the PoolManager and paid out through `claim`. Quote-denominated settings (caps, minimums) are
/// in the quote's own units. Only the bound launchpad can initialize a pool with this hook, and a
/// pool's config can never change after initialization.
contract AvaxHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    struct HookConfig {
        // ---- protection
        uint32 guardBlocks; // anti-snipe window (0 = off)
        uint96 maxBuyPerBlock; // cumulative AVAX buy cap per block during the guard (0 = no cap)
        uint16 snipeTaxBps; // extra cut on guarded buys, paid into a pot (or the protocol)
        uint32 whaleBlocks; // whale guard window (0 = off)
        uint96 maxBuyPerTx; // AVAX cap per buy during the whale window
        uint32 dumpBlocks; // dump guard window (0 = off)
        uint16 maxSellBps; // max tokens per sell, in bps of total supply
        uint32 mevBlocks; // MEV shield window (0 = off)
        uint64 maxPriorityFee; // wei per gas above basefee allowed during the MEV window
        uint32 sellTaxBlocks; // sell tax decay window (0 = off)
        uint24 sellTaxPips; // extra sell LP fee at open, decays to 0
        // ---- fees
        uint24 baseFeePips; // LP fee floor, 1e6 = 100%
        uint24 maxFeePips; // surge ceiling (== base disables surge)
        uint8 surgeSens; // 0..10
        uint16 volPipsPerTick; // volatility fee per tick moved this block (0 = off)
        uint24 volMaxPips; // volatility fee ceiling
        uint16 creatorFeeBps; // creator's fee on buys and sells, 0..10%
        uint16 referralBps; // AVAX share of buys to the referrer
        // ---- rewards and burn
        uint16 burnBps; // share of buy output burned
        uint16 lpBps; // share of buy input donated to LPs
        uint16 potBps; // share of buy input into the Nth-buy pot
        uint32 potEveryNBuys;
        uint96 potMinBuy;
        uint16 timerPotBps; // share of buy input into the last-buyer pot
        uint32 timerSeconds; // quiet time that ends a last-buyer round
        uint96 timerMinBuy;
        uint16 buybackBps; // share of sell output saved for buybacks
        uint96 buybackMaxSpend; // AVAX spent per buyback at most
    }

    struct PoolState {
        HookConfig cfg;
        bool initialized;
        address token;
        bool quoteIs0;
        address creator;
        uint64 openBlock;
        // anti-snipe accounting
        uint64 guardBlock;
        uint96 guardSpent;
        // volatility reference
        uint64 volBlock;
        int24 volStartTick;
        // nth-buy pot
        uint64 potLastBlock;
        uint64 potBuyCount;
        uint128 potWei;
        // last-buyer pot
        address timerLeader;
        uint64 timerLastBuyAt;
        uint128 timerPotWei;
        // buyback
        uint128 buybackWei;
        uint64 buybackLastBlock;
        // buyback reference price: two rolling checkpoints of the pre-swap sqrtPrice. `next` is taken at
        // the first swap once the previous one is REF_MIN_AGE_BLOCKS old, and then becomes `ref`.
        uint160 refSqrtPrice;
        uint64 refBlock;
        uint160 nextRefSqrtPrice;
        uint64 nextRefBlock;
        // totals
        uint128 totalBurned;
        uint128 totalBuybackBurned;
        uint128 totalLpDonated;
        uint128 totalPotPaid;
        uint128 totalSnipeTax;
        uint128 totalCreatorFees;
        uint128 totalReferral;
    }

    // ---------------------------------------------------------------- constants

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint24 public constant MAX_BASE_FEE_PIPS = 100_000; // creators pick the base LP fee, 0..10%
    uint24 public constant MAX_SURGE_FEE_PIPS = 100_000; // 10% ceiling for base + surge
    uint24 public constant MAX_SELL_TAX_PIPS = 200_000; // 20% extra on sells at open
    uint24 public constant MAX_VOL_FEE_PIPS = 50_000; // 5%
    uint24 public constant MAX_TOTAL_FEE_PIPS = 300_000; // hard ceiling on the LP fee override
    uint16 public constant MAX_BURN_BPS = 500;
    uint16 public constant MAX_BUY_CUT_BPS = 2_000; // lp + pot + timer pot + creator + referral
    uint16 public constant MAX_SELL_CUT_BPS = 1_500; // creator + buyback
    uint16 public constant MAX_CREATOR_FEE_BPS = 1_000; // creators set their own fee, up to 10%
    /// @notice Fixed protocol fee on every exact-input swap, in the quote asset. Never configurable.
    uint16 public constant PROTOCOL_FEE_BPS = 30; // 0.3%
    uint16 public constant MAX_REFERRAL_BPS = 200; // and never more than the creator fee it comes out of
    uint16 public constant MAX_SNIPE_TAX_BPS = 2_500;
    uint32 public constant MAX_GUARD_BLOCKS = 7_200; // ~2-4h on C-Chain
    uint32 public constant MAX_WINDOW_BLOCKS = 43_200; // ~half a day to a day on C-Chain
    // An MEV shield can't refuse ordinary tipped (or legacy gasPrice) transactions, and can't last long.
    uint64 public constant MIN_PRIORITY_CAP = 5 gwei;
    uint32 public constant MAX_MEV_BLOCKS = 1_800; // ~30-60 min on C-Chain
    // A buyback may move the price at most 5%: sqrtPrice moves by √0.95 ≈ 0.9747 / √1.05 ≈ 1.0247.
    uint256 internal constant SQRT_PRICE_DOWN_BPS = 9_747;
    uint256 internal constant SQRT_PRICE_UP_BPS = 10_247;
    uint32 public constant BUYBACK_COOLDOWN_BLOCKS = 30;
    /// @notice A buyback's price bound comes from a pre-swap price at least this many blocks old, so a
    ///         pump in the blocks right before it can't raise what the buyback is willing to pay.
    uint32 public constant REF_MIN_AGE_BLOCKS = 30;
    /// @notice A last-buyer pot without a leader goes to the creator after this long with no qualifying buy.
    uint32 public constant TIMER_ORPHAN_SECONDS = 30 days;
    // transient-storage namespaces for per-transaction volume
    bytes32 internal constant TX_BUY = keccak256("avaxhook.tx.buy");
    bytes32 internal constant TX_SELL = keccak256("avaxhook.tx.sell");

    uint160 public constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    // ---------------------------------------------------------------- storage

    IPoolManager public immutable poolManager;
    address public immutable deployer;
    address public launchpad;
    /// @notice The AvaxHook router: the only caller whose hookData (buyer, referrer) is trusted.
    address public router;
    /// @notice The only account besides the deployer that may run buybacks.
    address public keeper;

    mapping(PoolId => PoolState) internal _pools;
    mapping(address => address) internal _quoteOf; // token => quote asset
    /// @notice Owed balances: account => currency => amount. Backed 1:1 by ERC-6909 claims this
    ///         hook holds in the PoolManager.
    mapping(address => mapping(Currency => uint256)) public claimable;
    /// @notice A buyer's referrer, bound by their first router buy that named one; never changes.
    mapping(address => address) public referrerOf;

    // ---------------------------------------------------------------- events

    event PoolConfigured(PoolId indexed id, address indexed token, address indexed creator, HookConfig cfg);
    event HookCut(
        PoolId indexed id,
        bool isBuy,
        uint256 protocol,
        uint256 lp,
        uint256 pot,
        uint256 timerPot,
        uint256 creator,
        uint256 referral,
        uint256 buyback,
        uint256 snipeTax
    );
    event AutoBurn(PoolId indexed id, uint256 amount);
    event JackpotHit(PoolId indexed id, address indexed winner, uint256 amount, uint256 buyNumber);
    event TimerPotWon(PoolId indexed id, address indexed winner, uint256 amount);
    event BuybackBurn(PoolId indexed id, uint256 avaxSpent, uint256 tokensBurned);
    event Claimed(address indexed account, Currency indexed currency, address to, uint256 amount);
    event KeeperSet(address keeper);
    event ReferrerBound(address indexed buyer, address indexed referrer);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotLaunchpad();
    error AlreadyBound();
    error BadConfig();
    error NotConfigured();
    error AlreadyConfigured();
    error BadPoolKey();
    error MaxBuyExceeded(uint256 attempted, uint256 cap);
    error MaxSellExceeded(uint256 attempted, uint256 cap);
    error PriorityFeeTooHigh(uint256 paid, uint256 cap);
    error ExactOutputBlocked();
    error LiquidityLockedDuringGuard();
    error NothingToClaim();
    error BuybackNotReady();
    error PartialFillNotAllowed();
    error FullRangeOnly();
    error HookNotImplemented();
    error NotKeeper();

    /// @param _deployer who may bind the launchpad once (the hook itself is deployed through a
    ///        CREATE2 factory so its address carries the permission bits).
    constructor(IPoolManager _poolManager, address _deployer) {
        poolManager = _poolManager;
        deployer = _deployer;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function bindLaunchpad(address _launchpad) external {
        if (msg.sender != deployer) revert NotLaunchpad();
        if (launchpad != address(0) || _launchpad == address(0)) revert AlreadyBound();
        launchpad = _launchpad;
    }

    function bindRouter(address _router) external {
        if (msg.sender != deployer) revert NotLaunchpad();
        if (router != address(0) || _router == address(0)) revert AlreadyBound();
        router = _router;
    }

    /// @notice Sets (or, with address(0), clears) the buyback keeper.
    function setKeeper(address _keeper) external {
        if (msg.sender != deployer) revert NotKeeper();
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    // ---------------------------------------------------------------- config

    function validateConfig(HookConfig memory c) public pure {
        // protection
        if (c.guardBlocks > MAX_GUARD_BLOCKS || c.snipeTaxBps > MAX_SNIPE_TAX_BPS) revert BadConfig();
        if (c.whaleBlocks > MAX_WINDOW_BLOCKS || (c.whaleBlocks > 0 && c.maxBuyPerTx == 0)) revert BadConfig();
        if (c.dumpBlocks > MAX_WINDOW_BLOCKS || (c.dumpBlocks > 0 && (c.maxSellBps == 0 || c.maxSellBps > 1_000))) {
            revert BadConfig();
        }
        if (c.mevBlocks > MAX_MEV_BLOCKS || (c.mevBlocks > 0 && c.maxPriorityFee < MIN_PRIORITY_CAP)) revert BadConfig();
        if (c.sellTaxBlocks > MAX_WINDOW_BLOCKS || c.sellTaxPips > MAX_SELL_TAX_PIPS) revert BadConfig();
        if (c.sellTaxPips > 0 && c.sellTaxBlocks == 0) revert BadConfig();
        // fees
        if (c.baseFeePips > MAX_BASE_FEE_PIPS || c.maxFeePips < c.baseFeePips || c.maxFeePips > MAX_SURGE_FEE_PIPS) {
            revert BadConfig();
        }
        if (c.surgeSens > 10 || (c.maxFeePips > c.baseFeePips && c.surgeSens == 0)) revert BadConfig();
        if (c.volMaxPips > MAX_VOL_FEE_PIPS || (c.volPipsPerTick > 0 && c.volMaxPips == 0)) revert BadConfig();
        if (c.creatorFeeBps > MAX_CREATOR_FEE_BPS || c.referralBps > MAX_REFERRAL_BPS) revert BadConfig();
        // the referral reward is paid out of the creator fee, so it can never add cost for the buyer
        if (c.referralBps > c.creatorFeeBps) revert BadConfig();
        // rewards and burn
        if (c.burnBps > MAX_BURN_BPS) revert BadConfig();
        uint256 buyCut = uint256(c.lpBps) + c.potBps + c.timerPotBps + c.creatorFeeBps;
        if (buyCut > MAX_BUY_CUT_BPS) revert BadConfig();
        if (uint256(c.creatorFeeBps) + c.buybackBps > MAX_SELL_CUT_BPS) revert BadConfig();
        if (c.potBps > 0 && (c.potEveryNBuys < 2 || c.potEveryNBuys > 100_000 || c.potMinBuy == 0)) {
            revert BadConfig();
        }
        if (c.timerPotBps > 0 && (c.timerSeconds < 60 || c.timerSeconds > 7 days || c.timerMinBuy == 0)) {
            revert BadConfig();
        }
        if (c.buybackBps > 0 && c.buybackMaxSpend == 0) revert BadConfig();
    }

    /// @notice Called by the launchpad right before it initializes the pool. The fourth argument (the
    ///         protocol recipient) is ignored: protocol cuts always go to the launchpad's current recipient.
    function configurePool(PoolKey calldata key, address token, address creator, address, HookConfig calldata cfg)
        external
    {
        if (msg.sender != launchpad) revert NotLaunchpad();
        bool tokenIs1 = Currency.unwrap(key.currency1) == token;
        if (address(key.hooks) != address(this) || !key.fee.isDynamicFee()) revert BadPoolKey();
        if (!tokenIs1 && Currency.unwrap(key.currency0) != token) revert BadPoolKey();
        validateConfig(cfg);
        PoolState storage p = _pools[key.toId()];
        if (p.initialized) revert AlreadyConfigured();
        p.cfg = cfg;
        p.initialized = true;
        p.token = token;
        p.quoteIs0 = tokenIs1;
        p.creator = creator;
        p.openBlock = uint64(block.number);
        p.timerLastBuyAt = uint64(block.timestamp); // starts the orphaned last-buyer pot clock
        _quoteOf[token] = Currency.unwrap(tokenIs1 ? key.currency0 : key.currency1);
        emit PoolConfigured(key.toId(), token, creator, cfg);
    }

    // ---------------------------------------------------------------- hook callbacks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != launchpad) revert NotLaunchpad();
        if (!_pools[key.toId()].initialized) revert NotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender == launchpad) return IHooks.beforeAddLiquidity.selector;
        PoolState storage p = _pools[key.toId()];
        if (_within(p, p.cfg.guardBlocks)) revert LiquidityLockedDuringGuard();
        // Full range only: no just-in-time concentrated liquidity to skim LP donations or mute the surge fee.
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) revert FullRangeOnly();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (!p.initialized) revert NotConfigured();
        // (The hook's own buyback swap never reaches here: v4 skips a hook's callbacks for its own swaps.)

        // Exact input only. Every cut is priced off the input, so exact-output would skip them all.
        if (params.amountSpecified >= 0) revert ExactOutputBlocked();
        bool isBuy = params.zeroForOne == p.quoteIs0;
        uint256 amountIn = uint256(-params.amountSpecified);
        // Buys must be allowed to fill completely: cuts, pots and the guard cap are booked on the input,
        // so a price-limited partial fill would pay (or qualify) for more than it bought.
        if (isBuy) {
            uint160 limit = params.sqrtPriceLimitX96;
            if (params.zeroForOne ? limit != TickMath.MIN_SQRT_PRICE + 1 : limit != TickMath.MAX_SQRT_PRICE - 1) {
                revert PartialFillNotAllowed();
            }
        }
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        // Roll the buyback reference checkpoints (one storage read per swap, writes once per window).
        if (block.number >= uint256(p.nextRefBlock) + REF_MIN_AGE_BLOCKS) {
            p.refSqrtPrice = p.nextRefSqrtPrice;
            p.refBlock = p.nextRefBlock;
            p.nextRefSqrtPrice = sqrtPriceX96;
            p.nextRefBlock = uint64(block.number);
        }

        uint256 txVolume = _txAdd(id, isBuy, amountIn);
        _checkLimits(p, isBuy, amountIn, txVolume);
        uint256 feePips = _lpFee(id, p, params, txVolume, sqrtPriceX96, tick);

        uint256 cut;
        if (isBuy) cut = _takeBuyCuts(key, id, p, amountIn, sender, hookData);

        if (feePips > MAX_TOTAL_FEE_PIPS) feePips = MAX_TOTAL_FEE_PIPS;
        return (
            IHooks.beforeSwap.selector,
            cut == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(int128(int256(cut)), 0),
            uint24(feePips) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (params.amountSpecified >= 0) return (IHooks.afterSwap.selector, 0); // unreachable: beforeSwap reverts
        PoolId id = key.toId();
        PoolState storage p = _pools[id];

        (Currency quoteC, Currency tokenC) = p.quoteIs0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 quoteDelta = p.quoteIs0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = p.quoteIs0 ? delta.amount1() : delta.amount0();

        if (params.zeroForOne == p.quoteIs0) {
            // exact-input buy: auto burn from the token output
            int128 out = tokenDelta;
            if (p.cfg.burnBps == 0 || out <= 0) return (IHooks.afterSwap.selector, 0);
            uint256 burnAmount = (uint256(uint128(out)) * p.cfg.burnBps) / BPS;
            if (burnAmount == 0) return (IHooks.afterSwap.selector, 0);
            poolManager.take(tokenC, DEAD, burnAmount);
            p.totalBurned += uint128(burnAmount);
            emit AutoBurn(id, burnAmount);
            return (IHooks.afterSwap.selector, int128(int256(burnAmount)));
        }

        // exact-input sell: creator fee and buyback savings from the quote output
        int128 avaxOut = quoteDelta;
        uint256 creatorCut;
        uint256 protocolCut;
        uint256 buybackCut;
        if (avaxOut > 0) {
            uint256 o = uint256(uint128(avaxOut));
            creatorCut = (o * p.cfg.creatorFeeBps) / BPS;
            protocolCut = (o * PROTOCOL_FEE_BPS) / BPS;
            buybackCut = (o * p.cfg.buybackBps) / BPS;
        }
        uint256 total = creatorCut + buybackCut + protocolCut;
        if (total == 0) return (IHooks.afterSwap.selector, 0);
        poolManager.mint(address(this), quoteC.toId(), total);
        if (creatorCut > 0) {
            claimable[p.creator][quoteC] += creatorCut;
            p.totalCreatorFees += uint128(creatorCut);
        }
        if (buybackCut > 0) p.buybackWei += uint128(buybackCut);
        if (protocolCut > 0) claimable[_protocol()][quoteC] += protocolCut;
        emit HookCut(id, false, protocolCut, 0, 0, 0, creatorCut, 0, buybackCut, 0);
        return (IHooks.afterSwap.selector, int128(int256(total)));
    }

    // ---------------------------------------------------------------- permissionless actions

    /// @notice Withdraw what this hook owes you in one currency (pots, creator fees, referrals,
    ///         protocol share). Native AVAX is `Currency.wrap(address(0))`.
    function claim(Currency currency, address to) external {
        uint256 amount = claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender][currency] = 0;
        poolManager.unlock(abi.encode(uint8(0), abi.encode(currency, to, amount)));
        emit Claimed(msg.sender, currency, to, amount);
    }

    /// @notice Spends saved buyback funds (up to the per-buyback cap) buying the token and burns it.
    ///         Keeper (or deployer) only, once the cooldown has passed. The buyback moves the price at
    ///         most 5%, and never above 5% over the reference price (see `buybackReference`), so a pump
    ///         in the preceding blocks can't be sold into it.
    function executeBuyback(PoolKey calldata key) external returns (uint256 spent, uint256 burned) {
        if (msg.sender != keeper && msg.sender != deployer) revert NotKeeper();
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (!p.initialized || address(key.hooks) != address(this)) revert NotConfigured();
        // Runs once a tenth of the per-run cap is saved, so dust can't be used to churn the pool.
        if (p.buybackWei == 0 || p.buybackWei * 10 < p.cfg.buybackMaxSpend) revert BuybackNotReady();
        if (p.buybackLastBlock != 0 && block.number < p.buybackLastBlock + BUYBACK_COOLDOWN_BLOCKS) revert BuybackNotReady();
        (spent, burned) = abi.decode(poolManager.unlock(abi.encode(uint8(1), abi.encode(key))), (uint256, uint256));
    }

    /// @notice Pays out a last-buyer pot whose quiet time has passed.
    function settleTimerPot(PoolId id) external {
        _settleTimer(id, _pools[id]);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        if (action == 0) {
            (Currency currency, address to, uint256 amount) = abi.decode(body, (Currency, address, uint256));
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
            return "";
        }

        PoolKey memory key = abi.decode(body, (PoolKey));
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        uint256 budget = p.buybackWei;
        if (budget > p.cfg.buybackMaxSpend) budget = p.cfg.buybackMaxSpend;

        (uint160 sqrtStart,,,) = poolManager.getSlot0(id);
        uint256 ref = buybackReference(id);
        if (ref == 0) revert BuybackNotReady();
        bool zeroForOne = p.quoteIs0; // quote in, token out
        // Bound the price move to 5% in whichever direction a buy pushes it, measured from the spot price
        // and from the aged reference, whichever is tighter (clamped before the cast).
        // A buy lowers sqrtPrice when quote is currency0 and raises it otherwise. If the spot price is
        // already at or past the bound (a recent pump), there is nothing to buy.
        uint256 l;
        if (zeroForOne) {
            l = ((sqrtStart > ref ? sqrtStart : ref) * SQRT_PRICE_DOWN_BPS) / BPS;
            if (l >= sqrtStart) revert BuybackNotReady();
        } else {
            l = ((sqrtStart < ref ? sqrtStart : ref) * SQRT_PRICE_UP_BPS) / BPS;
            if (l <= sqrtStart) revert BuybackNotReady();
        }
        if (l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
        if (l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
        uint160 limit = uint160(l);
        BalanceDelta delta = poolManager.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(budget), sqrtPriceLimitX96: limit}), ""
        );
        (Currency quoteC, Currency tokenC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 qd, int128 td) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 spent = uint256(uint128(-qd));
        uint256 bought = uint256(uint128(td));
        if (spent == 0 || bought == 0) revert BuybackNotReady();

        poolManager.burn(address(this), quoteC.toId(), spent);
        poolManager.take(tokenC, DEAD, bought);
        p.buybackWei -= uint128(spent);
        p.buybackLastBlock = uint64(block.number);
        p.totalBuybackBurned += uint128(bought);
        emit BuybackBurn(id, spent, bought);
        return abi.encode(spent, bought);
    }

    // ---------------------------------------------------------------- views

    function poolState(PoolId id) external view returns (PoolState memory) {
        return _pools[id];
    }

    function guardActive(PoolId id) external view returns (bool) {
        PoolState storage p = _pools[id];
        return _within(p, p.cfg.guardBlocks);
    }

    /// @notice Buys until the next Nth-buy pot payout (1 = the next qualifying buy wins).
    function buysUntilPot(PoolId id) external view returns (uint256) {
        PoolState storage p = _pools[id];
        if (p.cfg.potBps == 0) return 0;
        return p.cfg.potEveryNBuys - (p.potBuyCount % p.cfg.potEveryNBuys);
    }

    /// @notice The sqrtPrice a buyback is bounded against: the newest pre-swap checkpoint that is at least
    ///         `REF_MIN_AGE_BLOCKS` old (0 before the pool has one).
    function buybackReference(PoolId id) public view returns (uint256) {
        PoolState storage p = _pools[id];
        if (p.nextRefSqrtPrice != 0 && block.number >= uint256(p.nextRefBlock) + REF_MIN_AGE_BLOCKS) {
            return p.nextRefSqrtPrice;
        }
        return p.refSqrtPrice;
    }

    /// @notice Current sell tax decay add-on in pips.
    function currentSellTax(PoolId id) public view returns (uint256) {
        PoolState storage p = _pools[id];
        uint256 window = p.cfg.sellTaxBlocks;
        if (window == 0 || p.openBlock == 0) return 0;
        uint256 elapsed = block.number - p.openBlock;
        if (elapsed >= window) return 0;
        return (uint256(p.cfg.sellTaxPips) * (window - elapsed)) / window;
    }

    // ---------------------------------------------------------------- internals

    function _within(PoolState storage p, uint32 window) internal view returns (bool) {
        return window != 0 && p.openBlock != 0 && block.number < p.openBlock + window;
    }

    /// @dev Window-bound limits: anti-snipe, whale guard, dump guard, MEV shield. Whale and dump caps
    ///      apply to the whole transaction (`txVolume`), so splitting into many swaps doesn't help.
    function _checkLimits(PoolState storage p, bool isBuy, uint256 amount, uint256 txVolume) internal {
        HookConfig storage c = p.cfg;

        if (_within(p, c.mevBlocks)) {
            uint256 priority = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
            if (priority > c.maxPriorityFee) revert PriorityFeeTooHigh(priority, c.maxPriorityFee);
        }

        if (isBuy) {
            bool guard = _within(p, c.guardBlocks);
            if (_within(p, c.whaleBlocks) && txVolume > c.maxBuyPerTx) revert MaxBuyExceeded(txVolume, c.maxBuyPerTx);
            if (guard && c.maxBuyPerBlock != 0) {
                uint256 spent = p.guardBlock == block.number ? p.guardSpent : 0;
                uint256 total = spent + amount;
                if (total > c.maxBuyPerBlock) revert MaxBuyExceeded(total, c.maxBuyPerBlock);
                p.guardBlock = uint64(block.number);
                p.guardSpent = uint96(total);
            }
        } else if (_within(p, c.dumpBlocks)) {
            uint256 cap = (1_000_000_000 ether * uint256(c.maxSellBps)) / BPS;
            if (txVolume > cap) revert MaxSellExceeded(txVolume, cap);
        }
    }

    /// @dev Adds `amount` to this transaction's running buy (or sell) volume for the pool and returns
    ///      the new total. Transient storage: it resets at the end of every transaction.
    function _txAdd(PoolId id, bool isBuy, uint256 amount) internal returns (uint256 total) {
        bytes32 slot = keccak256(abi.encode(isBuy ? TX_BUY : TX_SELL, id));
        assembly ("memory-safe") {
            total := add(tload(slot), amount)
            tstore(slot, total)
        }
    }

    function _protocol() internal view returns (address) {
        return IProtocolRecipient(launchpad).protocolRecipient();
    }

    /// @dev LP fee = base + surge (by this transaction's size) + volatility (by intra-block move) +
    ///      sell tax decay.
    function _lpFee(
        PoolId id,
        PoolState storage p,
        SwapParams calldata params,
        uint256 txVolume,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal returns (uint256 feePips) {
        HookConfig storage c = p.cfg;
        feePips = c.baseFeePips;

        // Sized on the transaction's cumulative volume so splitting a trade doesn't dodge the surge.
        if (c.maxFeePips > c.baseFeePips) feePips += _surge(id, c, sqrtPriceX96, params.zeroForOne, txVolume);

        if (c.volPipsPerTick > 0) {
            if (p.volBlock != block.number) {
                p.volBlock = uint64(block.number);
                p.volStartTick = tick;
            } else {
                int256 moved = int256(tick) - int256(p.volStartTick);
                uint256 extra = uint256(moved < 0 ? -moved : moved) * c.volPipsPerTick;
                feePips += extra > c.volMaxPips ? c.volMaxPips : extra;
            }
        }

        if (params.zeroForOne != p.quoteIs0) feePips += currentSellTax(id);
    }

    function _surge(PoolId id, HookConfig storage c, uint160 sqrtPriceX96, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0 || amountIn == 0 || sqrtPriceX96 == 0) return 0;
        uint256 reserveIn = zeroForOne
            ? (uint256(liquidity) << 96) / sqrtPriceX96
            : (uint256(liquidity) * sqrtPriceX96) >> 96;
        if (reserveIn == 0) return 0;
        uint256 ratio = (amountIn * c.surgeSens * PIPS) / reserveIn;
        if (ratio > PIPS) ratio = PIPS;
        return (uint256(c.maxFeePips - c.baseFeePips) * ratio) / PIPS;
    }

    struct Cuts {
        uint256 lp;
        uint256 pot;
        uint256 timer;
        uint256 creator;
        uint256 referral;
        uint256 snipe;
        uint256 protocol;
    }

    /// @dev Quote-side cuts on exact-input buys. Returns the total taken from the swap input.
    function _takeBuyCuts(
        PoolKey calldata key,
        PoolId id,
        PoolState storage p,
        uint256 amountIn,
        address sender,
        bytes calldata hookData
    ) internal returns (uint256 cut) {
        // Only the AvaxHook router's hookData is trusted: anyone else calling the PoolManager could
        // name any buyer (to win pots) or referrer (to rebate fees to themselves).
        (address buyer, address referrer) = sender == router ? _decodeHookData(hookData) : (address(0), address(0));
        if (p.cfg.referralBps == 0 || buyer == address(0)) referrer = address(0);
        else referrer = _bindReferrer(buyer, referrer);
        Cuts memory k = _cuts(p, amountIn, referrer);
        cut = k.lp + k.pot + k.timer + k.creator + k.referral + k.snipe + k.protocol;
        if (cut == 0) return 0;

        Currency quoteC = p.quoteIs0 ? key.currency0 : key.currency1;
        if (k.lp > 0) {
            if (p.quoteIs0) poolManager.donate(key, k.lp, 0, "");
            else poolManager.donate(key, 0, k.lp, "");
            p.totalLpDonated += uint128(k.lp);
        }
        if (cut > k.lp) poolManager.mint(address(this), quoteC.toId(), cut - k.lp);
        _credit(p, quoteC, k, referrer);
        emit HookCut(id, true, k.protocol, k.lp, k.pot, k.timer, k.creator, k.referral, 0, k.snipe);

        if (buyer != address(0)) {
            if (p.cfg.potBps > 0 && amountIn >= p.cfg.potMinBuy) _tickPot(id, p, buyer);
            if (p.cfg.timerPotBps > 0 && amountIn >= p.cfg.timerMinBuy) {
                _settleTimer(id, p);
                p.timerLeader = buyer;
                p.timerLastBuyAt = uint64(block.timestamp);
            }
        }
    }

    function _cuts(PoolState storage p, uint256 amountIn, address referrer) internal view returns (Cuts memory k) {
        HookConfig storage c = p.cfg;
        k.lp = (amountIn * c.lpBps) / BPS;
        k.pot = (amountIn * c.potBps) / BPS;
        k.timer = (amountIn * c.timerPotBps) / BPS;
        k.creator = (amountIn * c.creatorFeeBps) / BPS;
        k.protocol = (amountIn * PROTOCOL_FEE_BPS) / BPS;
        // The referral is carved out of the creator fee: the buyer pays the same with or without one.
        if (referrer != address(0)) {
            k.referral = (amountIn * c.referralBps) / BPS;
            if (k.referral > k.creator) k.referral = k.creator;
            k.creator -= k.referral;
        }
        if (_within(p, c.guardBlocks)) k.snipe = (amountIn * c.snipeTaxBps) / BPS;
    }

    /// @dev Books the non-LP cuts to pots and claim balances. Snipe tax funds a pot for everyone
    ///      after the snipers; with no pot it goes to the protocol.
    function _credit(PoolState storage p, Currency quoteC, Cuts memory k, address referrer) internal {
        if (k.snipe > 0) {
            p.totalSnipeTax += uint128(k.snipe);
            if (p.cfg.potBps > 0) k.pot += k.snipe;
            else if (p.cfg.timerPotBps > 0) k.timer += k.snipe;
            else claimable[_protocol()][quoteC] += k.snipe;
        }
        if (k.protocol > 0) claimable[_protocol()][quoteC] += k.protocol;
        if (k.pot > 0) p.potWei += uint128(k.pot);
        if (k.timer > 0) p.timerPotWei += uint128(k.timer);
        if (k.creator > 0) {
            claimable[p.creator][quoteC] += k.creator;
            p.totalCreatorFees += uint128(k.creator);
        }
        if (k.referral > 0) {
            claimable[referrer][quoteC] += k.referral;
            p.totalReferral += uint128(k.referral);
        }
    }

    /// @dev Router hookData is `abi.encode(buyer)` or `abi.encode(buyer, referrer)`. Swaps from any
    ///      other caller pay the same cuts but can't win pots or credit a referrer.
    function _decodeHookData(bytes calldata hookData) internal pure returns (address buyer, address referrer) {
        if (hookData.length == 32) buyer = abi.decode(hookData, (address));
        else if (hookData.length == 64) (buyer, referrer) = abi.decode(hookData, (address, address));
    }

    /// @dev Sticky referrals: a buyer's first valid referrer is bound and every later one is ignored, so a
    ///      buyer can't route each trade's referral to a fresh wallet of their own (or to whoever bids for
    ///      it). A referrer must not be the buyer or tx.origin, nor someone the buyer referred.
    function _bindReferrer(address buyer, address referrer) internal returns (address bound) {
        bound = referrerOf[buyer];
        if (bound == address(0)) {
            if (referrer == address(0) || referrer == buyer || referrer == tx.origin || referrerOf[referrer] == buyer) {
                return address(0);
            }
            referrerOf[buyer] = bound = referrer;
            emit ReferrerBound(buyer, referrer);
        }
        if (bound == tx.origin) bound = address(0);
    }

    /// @dev Deterministic Nth-buy pot: one qualifying slot per pool per block.
    function _tickPot(PoolId id, PoolState storage p, address winner) internal {
        if (p.potLastBlock == block.number) return;
        p.potLastBlock = uint64(block.number);
        uint64 count = p.potBuyCount + 1;
        p.potBuyCount = count;
        if (count % p.cfg.potEveryNBuys != 0) return;
        uint256 pot = p.potWei;
        if (pot == 0) return;
        p.potWei = 0;
        p.totalPotPaid += uint128(pot);
        claimable[winner][_quoteCurrency(p)] += pot;
        emit JackpotHit(id, winner, pot, count);
    }

    /// @dev Ends a last-buyer round when its quiet time has passed; the leader takes the pot.
    ///      A pot nobody leads (filled only by snipe tax or non-router buys) goes to the creator once
    ///      `TIMER_ORPHAN_SECONDS` pass without a qualifying buy, so it can't sit stuck for good.
    function _settleTimer(PoolId id, PoolState storage p) internal {
        address leader = p.timerLeader;
        if (leader == address(0)) {
            if (block.timestamp < uint256(p.timerLastBuyAt) + TIMER_ORPHAN_SECONDS) return;
            leader = p.creator;
        } else if (block.timestamp < uint256(p.timerLastBuyAt) + p.cfg.timerSeconds) {
            return;
        }
        uint256 pot = p.timerPotWei;
        p.timerLeader = address(0);
        if (pot == 0) return;
        p.timerPotWei = 0;
        p.totalPotPaid += uint128(pot);
        claimable[leader][_quoteCurrency(p)] += pot;
        emit TimerPotWon(id, leader, pot);
    }

    /// @dev The pool's quote currency, recovered from the stored orientation and token.
    function _quoteCurrency(PoolState storage p) internal view returns (Currency) {
        return Currency.wrap(_quoteOf[p.token]);
    }

    // ---------------------------------------------------------------- unused callbacks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
