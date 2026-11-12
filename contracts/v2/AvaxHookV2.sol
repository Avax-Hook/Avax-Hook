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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHookModule, ModuleCaps} from "./interfaces/IHookModule.sol";

interface IModuleSource {
    function forLaunch(uint32 id) external view returns (address impl, uint16 caps, uint32 groups);
}

interface IProtocolRecipientV2 {
    function protocolRecipient() external view returns (address);
}

/// @notice Defensive decoding of a module's swap-callback return data (already capped in size): anything
///         malformed reads as "no fee, no credits" instead of reverting the trade.
library ModuleReturn {
    /// @return f   extraFeePips (before-callbacks)
    /// @return ptr memory pointer to the first (to, amount) pair
    /// @return len credits to read, at most AvaxHookV2.MAX_CREDITS
    function decode(bytes memory ret, bool before) internal pure returns (uint256 f, uint256 ptr, uint256 len) {
        uint256 rl = ret.length;
        if (rl < (before ? 64 : 32)) return (0, 0, 0);
        uint256 o;
        assembly ("memory-safe") {
            let d := add(ret, 32)
            switch before
            case 0 { o := mload(d) }
            default {
                f := mload(d)
                o := mload(add(d, 32))
            }
        }
        if (f > type(uint24).max || o > rl || rl - o < 32) return (0, 0, 0);
        assembly ("memory-safe") {
            ptr := add(add(ret, 32), o)
            len := mload(ptr)
            ptr := add(ptr, 32)
        }
        if (len > 8) len = 8;
        if (len > (rl - o - 32) / 64) return (0, 0, 0);
    }
}

/// @title AvaxHookV2
/// @notice One Uniswap v4 hook for every AvaxHook v2 pool. It keeps the protocol-level rules itself and
///         runs each pool's module list (picked at launch from HookModuleRegistry, frozen forever) for
///         everything else, so new rules ship as new modules without redeploying the hook or launchpad.
///
///   Core (every pool, not configurable beyond the two creator knobs):
///   - 0.3% protocol fee on every swap in the quote asset (buys: from the input; sells: from the output).
///   - Creator fee (0..10%) on buys and sells, same sides.
///   - LP fee = creator's base fee + the modules' extra pips, capped at 30%, as a dynamic-fee override.
///   - Exact-input only (exact-output would skip every input-priced cut); every swap must fill completely.
///   - Full-range liquidity only for outside LPs (no JIT concentrated liquidity on donations).
///   - Buyer/seller identity only from the bound router's hookData; per-tx volume in transient storage.
///   - Pull claims: every credit is an ERC-6909 claim this hook holds in the PoolManager.
///
///   Module dispatch: see IHookModule for credits, capabilities and the failure model.
///
///   Curve phase: HookLaunchpadV2 calls `curveSwap` before and after every bonding-curve trade, and the
///   pool's modules run exactly as for pool swaps (same list, gas budget, sell isolation, 25% cap, kill
///   switch; per-tx counters shared with pool swaps) with `SwapContext.phase = PHASE_CURVE`. The launchpad
///   moves the credited amounts here (or to 0x…dEaD / the graduation liquidity); they back claims 1:1 as
///   plain balances (`held`) instead of ERC-6909 claims, and `claim` pays from those first.
///
///   Permissions (fixed by the address, chosen generously so future modules never need a new hook):
///     beforeInitialize        only the launchpad opens pools, and only registered ones
///     beforeAddLiquidity      full-range rule + module liquidity rules (anti-JIT, LP locks, guards)
///     beforeRemoveLiquidity   module liquidity rules (e.g. minimum LP age); isolated like sells
///     beforeSwap / afterSwap  core fees + module rules, fees and credits
///     beforeSwapReturnDelta   cuts from the input side
///     afterSwapReturnDelta    cuts from the output side (sell proceeds, buy output burn)
///   Not taken: after{Initialize,AddLiquidity,RemoveLiquidity} (nothing a module needs that before-hooks
///   don't give), donate hooks (the hook donates itself), liquidity return deltas (taxing LP principal is
///   a rug vector we never want to offer).
contract AvaxHookV2 is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    struct CoreConfig {
        uint16 creatorFeeBps; // creator's fee on buys and sells (curve and pool), 0..10%
        uint24 baseFeePips; // LP fee floor, 1e6 = 100%, 0..10%
    }

    struct Pool {
        // slot 0
        address token;
        bool quoteIs0;
        bool registered;
        uint16 creatorFeeBps;
        uint24 baseFeePips;
        uint8 nModules;
        uint16 caps; // OR of every module's capabilities
        // slot 1
        address creator;
        uint48 openedAt;
        uint48 openBlock;
        // slot 2: 16 bits of capabilities per module, module i at bits [16i, 16i+16)
        uint128 moduleCaps;
        uint48 launchedAt; // registration (= launch) timestamp
        address[8] modules;
    }

    /// @notice One side of a bonding-curve trade, sent by the launchpad (see `curveSwap`).
    struct CurveTrade {
        address token;
        address quote; // address(0) = native AVAX
        address sender; // the launchpad's msg.sender
        address trader; // the real buyer/seller (msg.sender, or `to` of a trusted caller's buy)
        bool isBuy;
        bool before; // true: onBeforeSwap (credits from the input); false: onAfterSwap (from the output)
        uint256 amountIn; // gross input as the modules see it (quote on buys, tokens on sells)
        uint256 amountOut; // curve output before after-trade cuts (0 before)
        uint160 sqrtPriceX96; // curve spot price in pool orientation, before / after the trade
        bytes data; // abi.encode(address referrer, bytes extra) or empty
    }

    /// @notice What the modules took from one side of a swap. `cut = held + burned + donated`.
    struct ModuleCuts {
        uint256 extraFeePips; // sum of extraFeePips (before-callbacks; curve: capped at MAX_TOTAL_FEE_PIPS)
        uint256 cut; // all credits, in the side's currency
        uint256 held; // credited to accounts (claimable here)
        uint256 burned; // to 0x…dEaD
        uint256 donated; // LP_DONATE
    }

    struct PoolView {
        address token;
        address quote;
        address creator;
        bool quoteIs0;
        uint16 creatorFeeBps;
        uint24 baseFeePips;
        uint16 caps;
        uint48 openedAt;
        uint48 openBlock;
        address[] modules;
        uint16[] moduleCaps;
    }

    // ---------------------------------------------------------------- constants

    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = ModuleCaps.BURN;
    uint16 public constant PROTOCOL_FEE_BPS = 30; // 0.3%, never configurable
    uint16 public constant MAX_CREATOR_FEE_BPS = 1_000;
    uint24 public constant MAX_BASE_FEE_PIPS = 100_000;
    uint24 public constant MAX_TOTAL_FEE_PIPS = 300_000;
    /// @notice Every module's credits together take at most this share of one side of a swap.
    uint16 public constant MAX_MODULE_CUT_BPS = 2_500;
    uint256 public constant MAX_MODULES = 8;
    /// @notice Gas each module callback gets at most.
    uint256 public constant MODULE_GAS = 200_000;
    /// @dev An isolated call must really get MODULE_GAS (63/64 rule + call overhead), so nobody can make it
    ///      fail on purpose by sending a transaction with just too little gas.
    uint256 internal constant ISOLATED_MIN_GAS = (MODULE_GAS * 64) / 63 + 10_000;
    /// @notice Claim account the protocol fee accrues to; paid out to the launchpad's current recipient.
    address public constant PROTOCOL = address(uint160(uint256(keccak256("avaxhook.v2.protocol"))));
    bytes32 internal constant TX_BUY = keccak256("avaxhook.v2.tx.buy");
    bytes32 internal constant TX_SELL = keccak256("avaxhook.v2.tx.sell");
    bytes32 internal constant TX_SWAPS = keccak256("avaxhook.v2.tx.swaps");
    bytes32 internal constant TX_DISPATCH = keccak256("avaxhook.v2.tx.dispatch");
    /// @notice Credits read from one module callback at most (extras are ignored).
    uint256 public constant MAX_CREDITS = 8;

    uint160 public constant REQUIRED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    // ---------------------------------------------------------------- storage

    IPoolManager public immutable poolManager;
    address public immutable deployer;
    IModuleSource public immutable moduleRegistry;
    /// @notice The live QuoteRegistry (USD prices), for modules that need market caps.
    address public immutable quoteRegistry;
    address public launchpad;
    /// @notice The AvaxHook v2 router: the only caller whose hookData (trader, referrer, extra) is trusted.
    address public router;
    uint96 public disabledCount;

    mapping(PoolId => Pool) internal _pools;
    mapping(address => PoolId) public poolOfToken;
    mapping(address => bool) public disabled;
    /// @notice Owed balances: account => currency => amount, backed 1:1 by ERC-6909 claims held here.
    mapping(address => mapping(Currency => uint256)) public claimable;
    /// @notice Part of the claims held as plain balances in this contract (curve-phase credits); the rest
    ///         is ERC-6909 claims in the PoolManager. Payouts and module swaps use this first.
    mapping(Currency => uint256) public held;

    // ---------------------------------------------------------------- events

    event PoolRegistered(
        PoolId indexed id, address indexed token, address indexed creator, CoreConfig core, uint32[] moduleIds, address[] modules
    );
    event PoolOpened(PoolId indexed id, uint256 timestamp);
    event CoreCut(PoolId indexed id, bool isBuy, uint256 protocol, uint256 creator);
    event ModuleCredit(PoolId indexed id, address indexed module, address indexed to, Currency currency, uint256 amount);
    event ModuleFailed(PoolId indexed id, address indexed module, bytes4 callback);
    event ModuleDisabled(address indexed module);
    event ModuleSwap(PoolId indexed id, address indexed module, bool buy, uint256 spent, uint256 out, bool burned);
    event Claimed(address indexed account, Currency indexed currency, address to, uint256 amount);
    event ClaimTransferred(address indexed from, address indexed to, Currency indexed currency, uint256 amount);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotLaunchpad();
    error NotRegistry();
    error NotModule();
    error AlreadyBound();
    error BadConfig();
    error BadPoolKey();
    error NotConfigured();
    error AlreadyConfigured();
    error ModuleConflict(uint32 id);
    error ExactOutputBlocked();
    error PartialFillNotAllowed();
    error FullRangeOnly();
    error NeedMoreGas();
    error NothingToClaim();
    error UnknownToken();
    error HookNotImplemented();
    error TransferFailed();
    /// @notice `simulateCurve` always reverts with this (the cuts each simulated call would take).
    error CurveSimulation(ModuleCuts[] cuts);

    constructor(IPoolManager _poolManager, address _deployer, IModuleSource _registry, address _quoteRegistry) {
        poolManager = _poolManager;
        deployer = _deployer;
        moduleRegistry = _registry;
        quoteRegistry = _quoteRegistry;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev The PoolManager (takes) and the launchpad (curve credits in native AVAX).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != launchpad) revert NotPoolManager();
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
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

    /// @notice Emergency kill from the registry (irreversible): the module is skipped in every pool.
    function disableModule(address module) external {
        if (msg.sender != address(moduleRegistry)) revert NotRegistry();
        if (disabled[module]) return;
        disabled[module] = true;
        disabledCount += 1;
        emit ModuleDisabled(module);
    }

    // ---------------------------------------------------------------- registration (launch time)

    function validateCore(CoreConfig calldata core) public pure {
        if (core.creatorFeeBps > MAX_CREATOR_FEE_BPS || core.baseFeePips > MAX_BASE_FEE_PIPS) revert BadConfig();
    }

    /// @notice Called by the launchpad when a token launches. Resolves the module ids (each must be active
    ///         in the registry), validates their configs and conflict groups, and freezes the list.
    /// @return caps OR of the modules' capabilities (the launchpad turns on token transfer callbacks
    ///         when it includes ON_TRANSFER)
    function registerPool(
        PoolKey calldata key,
        address token,
        address creator,
        CoreConfig calldata core,
        uint32[] calldata ids,
        bytes[] calldata configs
    ) external returns (uint16 caps) {
        if (msg.sender != launchpad) revert NotLaunchpad();
        bool tokenIs1 = Currency.unwrap(key.currency1) == token;
        if (address(key.hooks) != address(this) || !LPFeeLibrary.isDynamicFee(key.fee)) revert BadPoolKey();
        if (!tokenIs1 && Currency.unwrap(key.currency0) != token) revert BadPoolKey();
        validateCore(core);
        uint256 n = ids.length;
        if (n > MAX_MODULES || configs.length != n) revert BadConfig();
        PoolId id = key.toId();
        Pool storage p = _pools[id];
        if (p.registered) revert AlreadyConfigured();

        p.token = token;
        p.quoteIs0 = tokenIs1;
        p.registered = true;
        p.creatorFeeBps = core.creatorFeeBps;
        p.baseFeePips = core.baseFeePips;
        p.nModules = uint8(n);
        p.creator = creator;
        p.launchedAt = uint48(block.timestamp);
        poolOfToken[token] = id;

        address quote = Currency.unwrap(tokenIs1 ? key.currency0 : key.currency1);
        address[] memory impls = new address[](n);
        uint32 groupsSeen;
        uint128 packed;
        for (uint256 i; i < n; ++i) {
            (address impl, uint16 mc, uint32 groups) = moduleRegistry.forLaunch(ids[i]);
            if (groups & groupsSeen != 0) revert ModuleConflict(ids[i]);
            for (uint256 j; j < i; ++j) {
                if (impls[j] == impl) revert ModuleConflict(ids[i]);
            }
            groupsSeen |= groups;
            impls[i] = impl;
            p.modules[i] = impl;
            packed |= uint128(mc) << (16 * i);
            caps |= mc;
            IHookModule(impl).validateConfig(configs[i]);
            IHookModule(impl).onRegister(id, token, quote, creator, configs[i]);
        }
        p.moduleCaps = packed;
        p.caps = caps;
        emit PoolRegistered(id, token, creator, core, ids, impls);
    }

    // ---------------------------------------------------------------- v4 callbacks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != launchpad) revert NotLaunchpad();
        Pool storage p = _pools[key.toId()];
        if (!p.registered || p.openedAt != 0) revert NotConfigured();
        p.openedAt = uint48(block.timestamp);
        p.openBlock = uint48(block.number);
        emit PoolOpened(key.toId(), block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender == launchpad) return IHooks.beforeAddLiquidity.selector;
        // Full range only: no just-in-time concentrated liquidity to skim LP donations or mute fees.
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) revert FullRangeOnly();
        _runLiquidity(key.toId(), sender, true, params);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        // The launchpad's locked position never shrinks; its fee collection (liquidityDelta 0) lands here.
        if (sender != launchpad) _runLiquidity(key.toId(), sender, false, params);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev public virtual (not external) only so the pools-profile subclass (AvaxHookPoolsV1) can wrap it;
    ///      the launch hook's behaviour is unchanged.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        public
        virtual
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Pool storage p = _pools[id];
        if (p.openedAt == 0) revert NotConfigured();
        // (The hook's own module swaps never reach here: v4 skips a hook's callbacks for its own swaps.)
        // Exact input only: every cut is priced off the input, so exact-output would skip them all.
        if (params.amountSpecified >= 0) revert ExactOutputBlocked();
        bool isBuy = params.zeroForOne == p.quoteIs0;
        uint256 amountIn = uint256(-params.amountSpecified);
        // Every swap must fill completely (extreme price limit): modules see the requested input, so a
        // price-limited partial fill could pay, qualify or count for more than it traded (H-1: a 2-wei
        // fill counted as a 5M-token sell).
        {
            uint160 limit = params.sqrtPriceLimitX96;
            if (params.zeroForOne ? limit != TickMath.MIN_SQRT_PRICE + 1 : limit != TickMath.MAX_SQRT_PRICE - 1) {
                revert PartialFillNotAllowed();
            }
        }
        uint256 txVolume = _txAdd(id, isBuy, amountIn);

        Currency inC = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 cut;
        uint256 toMint;
        if (isBuy) {
            (cut, toMint) = _coreCut(id, p, inC, amountIn, true);
        }
        uint256 feePips = p.baseFeePips;
        if (p.caps & ModuleCaps.BEFORE_SWAP != 0) {
            IHookModule.SwapContext memory ctx = _context(sender, key, id, p, isBuy, amountIn, 0, txVolume, hookData);
            ModuleCuts memory m = _runSwap(p, ctx, inC, amountIn, true);
            _poolMoves(key, inC, m);
            feePips += m.extraFeePips;
            cut += m.cut;
            toMint += m.held;
        }
        if (toMint > 0) poolManager.mint(address(this), inC.toId(), toMint);
        if (feePips > MAX_TOTAL_FEE_PIPS) feePips = MAX_TOTAL_FEE_PIPS;
        return (
            IHooks.beforeSwap.selector,
            cut == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(int128(int256(cut)), 0),
            uint24(feePips) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev public virtual: see beforeSwap.
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        public
        virtual
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Pool storage p = _pools[id];
        bool isBuy = params.zeroForOne == p.quoteIs0;
        Currency outC = params.zeroForOne ? key.currency1 : key.currency0;
        int128 outDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amountOut = outDelta > 0 ? uint256(uint128(outDelta)) : 0;

        uint256 cut;
        uint256 toMint;
        if (!isBuy) (cut, toMint) = _coreCut(id, p, outC, amountOut, false);
        if (p.caps & ModuleCaps.AFTER_SWAP != 0) {
            uint256 amountIn = uint256(-params.amountSpecified);
            IHookModule.SwapContext memory ctx =
                _context(sender, key, id, p, isBuy, amountIn, amountOut, _txGet(id, isBuy), hookData);
            ModuleCuts memory m = _runSwap(p, ctx, outC, amountOut, false);
            _poolMoves(key, outC, m);
            cut += m.cut;
            toMint += m.held;
        }
        if (toMint > 0) poolManager.mint(address(this), outC.toId(), toMint);
        return (IHooks.afterSwap.selector, int128(int256(cut)));
    }

    // ---------------------------------------------------------------- curve phase

    /// @notice Runs the pool's swap modules for one side of a bonding-curve trade. Launchpad only; it must
    ///         then move `held` here, `burned` to 0x…dEaD and handle `donated` (quote: graduation liquidity,
    ///         tokens: burned) in the same transaction. Claims are booked here, before the funds arrive.
    function curveSwap(CurveTrade calldata t) external returns (ModuleCuts memory) {
        if (msg.sender != launchpad) revert NotLaunchpad();
        return _curve(t);
    }

    /// @notice Dry run of curve-trade callbacks for quotes (HookLensV2): runs `ts` in order, then reverts
    ///         with CurveSimulation(cuts), so nothing it does persists. A module refusing reverts with its
    ///         own reason instead. Use via eth_call.
    function simulateCurve(CurveTrade[] calldata ts) external {
        ModuleCuts[] memory r = new ModuleCuts[](ts.length);
        for (uint256 i; i < ts.length; ++i) {
            r[i] = _curve(ts[i]);
        }
        revert CurveSimulation(r);
    }

    function _curve(CurveTrade calldata t) internal returns (ModuleCuts memory r) {
        PoolId id = poolOfToken[t.token];
        Pool storage p = _pools[id];
        if (p.token != t.token || t.token == address(0)) revert UnknownToken();
        if (p.openedAt != 0) revert AlreadyConfigured(); // graduated: the curve is closed
        uint256 txVolume = t.before ? _txAdd(id, t.isBuy, t.amountIn) : _txGet(id, t.isBuy);
        if (p.caps & (t.before ? ModuleCaps.BEFORE_SWAP : ModuleCaps.AFTER_SWAP) == 0) return r;
        IHookModule.SwapContext memory ctx;
        ctx.poolId = id;
        ctx.token = t.token;
        ctx.quote = t.quote;
        ctx.creator = p.creator;
        ctx.sender = t.sender;
        ctx.trader = t.trader;
        if (t.data.length >= 64) (ctx.referrer, ctx.extra) = abi.decode(t.data, (address, bytes));
        ctx.isBuy = t.isBuy;
        ctx.amountIn = t.amountIn;
        ctx.amountOut = t.amountOut;
        ctx.txVolume = txVolume;
        ctx.txSwaps = _txSwaps(id);
        ctx.sqrtPriceX96 = t.sqrtPriceX96;
        ctx.phase = ModuleCaps.PHASE_CURVE;
        // before: the input (quote on buys, tokens on sells); after: the output
        Currency c = Currency.wrap(t.before == t.isBuy ? t.quote : t.token);
        r = _runSwap(p, ctx, c, t.before ? t.amountIn : t.amountOut, t.before);
        if (r.extraFeePips > MAX_TOTAL_FEE_PIPS) r.extraFeePips = MAX_TOTAL_FEE_PIPS;
        if (r.held > 0) held[c] += r.held;
    }

    // ---------------------------------------------------------------- token transfer callback

    /// @notice Called by a v2 token (only one whose pool has an ON_TRANSFER module) after every move except
    ///         mints and burns. Exit moves (to the PoolManager or the curve) are the sell path: modules
    ///         without BLOCKS_SELLS are isolated there.
    function onTokenTransfer(address operator, address from, address to, uint256 amount) external {
        PoolId id = poolOfToken[msg.sender];
        Pool storage p = _pools[id];
        if (p.token != msg.sender || msg.sender == address(0)) revert UnknownToken();
        if (p.caps & ModuleCaps.ON_TRANSFER == 0) return;
        // Graduation seeding the pool, burning dust and moving curve credits here is protocol plumbing,
        // never subject to rules.
        if (from == launchpad && (to == address(poolManager) || to == DEAD || to == address(this))) return;
        bool exit = to == address(poolManager) || to == launchpad;
        uint256 n = p.nModules;
        uint256 packed = p.moduleCaps;
        bool checkDisabled = disabledCount != 0;
        for (uint256 i; i < n; ++i) {
            uint16 mc = uint16(packed >> (16 * i));
            if (mc & ModuleCaps.ON_TRANSFER == 0) continue;
            address m = p.modules[i];
            if (checkDisabled && disabled[m]) continue;
            _call(
                id,
                m,
                abi.encodeCall(IHookModule.onTransfer, (id, msg.sender, operator, from, to, amount)),
                exit && mc & ModuleCaps.BLOCKS_SELLS == 0
            );
        }
    }

    // ---------------------------------------------------------------- claims

    /// @notice Withdraw what this hook owes you in one currency. Native AVAX is `Currency.wrap(address(0))`.
    function claim(Currency currency, address to) external {
        _payout(msg.sender, currency, to);
    }

    /// @notice Pays the accrued protocol fee to the launchpad's current protocol recipient. Permissionless.
    function claimProtocol(Currency currency) external {
        _payout(PROTOCOL, currency, IProtocolRecipientV2(launchpad).protocolRecipient());
    }

    /// @notice Moves part of your claimable balance to someone else (modules pay pots and rewards this way).
    function transferClaim(Currency currency, address to, uint256 amount) external {
        if (to == address(0)) revert BadConfig();
        claimable[msg.sender][currency] -= amount;
        claimable[to][currency] += amount;
        emit ClaimTransferred(msg.sender, to, currency, amount);
    }

    /// @notice A module spends its own claimable balance on a swap in one of its pools (buybacks, vault
    ///         rebalancing). The hook's own swaps skip every hook callback (v4), so no fees or modules run;
    ///         the module is responsible for who may trigger this and for a manipulation-safe price limit
    ///         (keeper-only + an aged reference price, as v1's buyback). Output is burned or credited back
    ///         to the module.
    function moduleSwap(PoolKey calldata key, bool buy, uint256 amountIn, uint160 sqrtPriceLimitX96, bool burnOut)
        external
        returns (uint256 spent, uint256 out)
    {
        PoolId id = key.toId();
        Pool storage p = _pools[id];
        if (address(key.hooks) != address(this) || p.openedAt == 0) revert NotConfigured();
        if (!_isModuleOf(p, msg.sender) || disabled[msg.sender]) revert NotModule();
        bool zeroForOne = buy == p.quoteIs0;
        Currency inC = zeroForOne ? key.currency0 : key.currency1;
        claimable[msg.sender][inC] -= amountIn;
        (spent, out) = abi.decode(
            poolManager.unlock(abi.encode(uint8(1), abi.encode(key, zeroForOne, amountIn, sqrtPriceLimitX96, burnOut, msg.sender))),
            (uint256, uint256)
        );
        if (amountIn > spent) claimable[msg.sender][inC] += amountIn - spent;
        emit ModuleSwap(id, msg.sender, buy, spent, out, burnOut);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        if (action == 0) {
            (Currency currency, address to, uint256 amount) = abi.decode(body, (Currency, address, uint256));
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
            return "";
        }
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, bool burnOut, address module) =
            abi.decode(body, (PoolKey, bool, uint256, uint160, bool, address));
        BalanceDelta delta =
            poolManager.swap(key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), "");
        (Currency inC, Currency outC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 di, int128 dout) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 spent = uint256(uint128(-di));
        uint256 out = uint256(uint128(dout));
        if (spent > 0) {
            // Pay from plain balances (curve credits) first, then from ERC-6909 claims.
            uint256 h = held[inC];
            uint256 fromHeld = h < spent ? h : spent;
            if (fromHeld > 0) {
                held[inC] = h - fromHeld;
                if (inC.isAddressZero()) {
                    poolManager.settle{value: fromHeld}();
                } else {
                    poolManager.sync(inC);
                    IERC20(Currency.unwrap(inC)).safeTransfer(address(poolManager), fromHeld);
                    poolManager.settle();
                }
            }
            if (spent > fromHeld) poolManager.burn(address(this), inC.toId(), spent - fromHeld);
        }
        if (out > 0) {
            if (burnOut) {
                poolManager.take(outC, DEAD, out);
            } else {
                poolManager.mint(address(this), outC.toId(), out);
                claimable[module][outC] += out;
            }
        }
        return abi.encode(spent, out);
    }

    // ---------------------------------------------------------------- views

    function poolInfo(PoolId id) external view returns (PoolView memory v) {
        Pool storage p = _pools[id];
        v.token = p.token;
        v.creator = p.creator;
        v.quoteIs0 = p.quoteIs0;
        v.creatorFeeBps = p.creatorFeeBps;
        v.baseFeePips = p.baseFeePips;
        v.caps = p.caps;
        v.openedAt = p.openedAt;
        v.openBlock = p.openBlock;
        uint256 n = p.nModules;
        v.modules = new address[](n);
        v.moduleCaps = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            v.modules[i] = p.modules[i];
            v.moduleCaps[i] = uint16(p.moduleCaps >> (16 * i));
        }
    }

    /// @notice True once the pool has graduated (v4 pool initialized).
    function isOpen(PoolId id) external view returns (bool) {
        return _pools[id].openedAt != 0;
    }

    function openedAt(PoolId id) external view returns (uint256) {
        return _pools[id].openedAt;
    }

    /// @notice Launch timestamp (the curve opened); for rules that count from launch rather than graduation.
    function launchedAt(PoolId id) external view returns (uint256) {
        return _pools[id].launchedAt;
    }

    function capsOf(PoolId id) external view returns (uint16) {
        return _pools[id].caps;
    }

    // ---------------------------------------------------------------- internals

    /// @dev 0.3% protocol fee + creator fee, booked as claims (minted by the caller with the module credits).
    function _coreCut(PoolId id, Pool storage p, Currency c, uint256 amount, bool isBuy)
        internal
        returns (uint256 cut, uint256 toMint)
    {
        uint256 prot = (amount * PROTOCOL_FEE_BPS) / BPS;
        uint256 cr = (amount * p.creatorFeeBps) / BPS;
        if (prot > 0) claimable[PROTOCOL][c] += prot;
        if (cr > 0) claimable[p.creator][c] += cr;
        cut = prot + cr;
        toMint = cut;
        if (cut > 0) emit CoreCut(id, isBuy, prot, cr);
    }

    function _context(
        address sender,
        PoolKey calldata key,
        PoolId id,
        Pool storage p,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 txVolume,
        bytes calldata hookData
    ) internal view returns (IHookModule.SwapContext memory ctx) {
        ctx.poolId = id;
        ctx.token = p.token;
        ctx.quote = Currency.unwrap(p.quoteIs0 ? key.currency0 : key.currency1);
        ctx.creator = p.creator;
        ctx.sender = sender;
        // Only the bound router's hookData is trusted: anyone else calling the PoolManager could name any
        // trader (to win crowns and pots) or referrer.
        if (sender == router && hookData.length >= 64) {
            (ctx.trader, ctx.referrer, ctx.extra) = abi.decode(hookData, (address, address, bytes));
        }
        ctx.isBuy = isBuy;
        ctx.amountIn = amountIn;
        ctx.amountOut = amountOut;
        ctx.txVolume = txVolume;
        ctx.txSwaps = _txSwaps(id);
        (ctx.sqrtPriceX96,,,) = poolManager.getSlot0(id);
    }

    /// @dev Runs every module with the callback's capability; returns the extra LP fee and the credits
    ///      taken from `side` (`amount` is the side's size, for the cut cap). Claims are booked to
    ///      `claimable`; the caller backs them (`held`), and moves `burned` / `donated`.
    function _runSwap(Pool storage p, IHookModule.SwapContext memory ctx, Currency c, uint256 amount, bool before)
        internal
        returns (ModuleCuts memory r)
    {
        uint256 n = p.nModules;
        uint256 packed = p.moduleCaps;
        bool checkDisabled = disabledCount != 0;
        uint16 need = before ? ModuleCaps.BEFORE_SWAP : ModuleCaps.AFTER_SWAP;
        uint256 maxCut = (amount * MAX_MODULE_CUT_BPS) / BPS;
        bytes memory data = before
            ? abi.encodeCall(IHookModule.onBeforeSwap, (ctx))
            : abi.encodeCall(IHookModule.onAfterSwap, (ctx));
        // Every module runs first; credits are booked after, scaled down together if they ask for more
        // than the cap (never a revert: pool-only cuts must not brick trading after graduation).
        // buf: [module, to, amount] per credit.
        uint256[] memory buf = new uint256[](3 * MAX_CREDITS * n);
        uint256 cnt;
        uint256 total;
        bool outer = _dispatchStart();
        for (uint256 i; i < n; ++i) {
            uint16 mc = uint16(packed >> (16 * i));
            if (mc & need == 0) continue;
            address m = p.modules[i];
            if (checkDisabled && disabled[m]) continue;
            (bool ok, bytes memory ret) = _call(ctx.poolId, m, data, !ctx.isBuy && mc & ModuleCaps.BLOCKS_SELLS == 0);
            if (!ok) continue;
            uint256 f;
            (f, cnt, total) = _collect(buf, cnt, total, ret, before, m, maxCut);
            r.extraFeePips += f;
        }
        _bookAll(ctx.poolId, c, buf, cnt, total, maxCut, r);
        if (outer) _dispatchMark();
    }

    /// @dev Appends a module's credits (decoded defensively) to `buf`.
    function _collect(uint256[] memory buf, uint256 cnt, uint256 total, bytes memory ret, bool before, address m, uint256 maxCut)
        internal
        pure
        returns (uint256 f, uint256, uint256)
    {
        uint256 ptr;
        uint256 len;
        (f, ptr, len) = ModuleReturn.decode(ret, before);
        for (uint256 k; k < len; ++k) {
            uint256 to;
            uint256 amt;
            assembly ("memory-safe") {
                to := mload(add(ptr, shl(6, k)))
                amt := mload(add(ptr, add(shl(6, k), 32)))
            }
            // Malformed or empty credits are skipped; one credit never counts for more than the cap, so the
            // sums can't overflow.
            if (to == 0 || to >> 160 != 0 || amt == 0) continue;
            if (amt > maxCut) amt = maxCut;
            (buf[cnt], buf[cnt + 1], buf[cnt + 2]) = (uint160(m), to, amt);
            cnt += 3;
            total += amt;
        }
        return (f, cnt, total);
    }

    /// @dev Books the collected credits in currency `c` into `r` (claims to `claimable`, burns and donations
    ///      as totals), each scaled by maxCut / total when the modules asked for more than the cap.
    function _bookAll(PoolId id, Currency c, uint256[] memory buf, uint256 cnt, uint256 total, uint256 maxCut, ModuleCuts memory r)
        internal
    {
        for (uint256 j; j < cnt; j += 3) {
            uint256 amt = total > maxCut ? (buf[j + 2] * maxCut) / total : buf[j + 2];
            if (amt == 0) continue;
            address to = address(uint160(buf[j + 1]));
            if (to == DEAD) {
                r.burned += amt;
            } else if (to == ModuleCaps.LP_DONATE) {
                r.donated += amt;
            } else {
                claimable[to][c] += amt;
                r.held += amt;
            }
            r.cut += amt;
            emit ModuleCredit(id, address(uint160(buf[j])), to, c, amt);
        }
    }

    /// @notice Odd while the hook is running a swap callback's modules and has not booked their credits yet
    ///         (changes on every start and end; transient). Ledger modules use it to tell a credit they
    ///         announced in the running callback (not booked yet) from one the hook already settled.
    ///         A swap nested inside a module callback leaves it unchanged: the whole outer dispatch,
    ///         nested credits included, counts as one still-running callback until the outer one ends.
    function dispatchId() external view returns (uint256 d) {
        bytes32 s = TX_DISPATCH;
        assembly ("memory-safe") {
            d := tload(s)
        }
    }

    /// @dev Starts a dispatch unless one is already running (nested swap); true if this one started it.
    function _dispatchStart() internal returns (bool outer) {
        bytes32 s = TX_DISPATCH;
        assembly ("memory-safe") {
            let d := tload(s)
            outer := iszero(and(d, 1))
            if outer { tstore(s, add(d, 1)) }
        }
    }

    function _dispatchMark() internal {
        bytes32 s = TX_DISPATCH;
        assembly ("memory-safe") {
            tstore(s, add(tload(s), 1))
        }
    }

    /// @dev Pool phase: burns and LP donations of the module credits go through the PoolManager.
    function _poolMoves(PoolKey calldata key, Currency c, ModuleCuts memory m) internal {
        if (m.burned > 0) poolManager.take(c, DEAD, m.burned);
        if (m.donated > 0) {
            bool is0 = Currency.unwrap(c) == Currency.unwrap(key.currency0);
            poolManager.donate(key, is0 ? m.donated : 0, is0 ? 0 : m.donated, "");
        }
    }

    function _runLiquidity(PoolId id, address sender, bool isAdd, ModifyLiquidityParams calldata params) internal {
        Pool storage p = _pools[id];
        if (p.caps & ModuleCaps.LIQUIDITY == 0) return;
        uint256 n = p.nModules;
        uint256 packed = p.moduleCaps;
        bool checkDisabled = disabledCount != 0;
        for (uint256 i; i < n; ++i) {
            uint16 mc = uint16(packed >> (16 * i));
            if (mc & ModuleCaps.LIQUIDITY == 0) continue;
            address m = p.modules[i];
            if (checkDisabled && disabled[m]) continue;
            // Removing liquidity is an exit like a sell: isolated unless the module may block sells.
            _call(
                id,
                m,
                abi.encodeCall(IHookModule.onLiquidity, (id, sender, isAdd, params)),
                !isAdd && mc & ModuleCaps.BLOCKS_SELLS == 0
            );
        }
    }

    /// @dev Calls a module with at most MODULE_GAS. Not isolated: a revert bubbles up (the rule said no).
    ///      Isolated: the call is guaranteed its full budget and a revert is logged and ignored. Return
    ///      data is copied up to MAX_RET bytes only (a module can't make the caller pay for huge returns).
    function _call(PoolId id, address m, bytes memory data, bool isolated) internal returns (bool ok, bytes memory ret) {
        if (isolated && gasleft() < ISOLATED_MIN_GAS) revert NeedMoreGas();
        assembly ("memory-safe") {
            ok := call(200000, m, 0, add(data, 32), mload(data), 0, 0)
            let size := returndatasize()
            if and(iszero(ok), iszero(isolated)) {
                let fmp := mload(0x40)
                returndatacopy(fmp, 0, size)
                revert(fmp, size)
            }
            if gt(size, 608) { size := 608 } // MAX_RET: fee + offset + length + MAX_CREDITS credits
            ret := mload(0x40)
            mstore(ret, size)
            returndatacopy(add(ret, 32), 0, size)
            mstore(0x40, add(add(ret, 32), and(add(size, 31), not(31))))
        }
        if (!ok) emit ModuleFailed(id, m, bytes4(data));
    }

    function _isModuleOf(Pool storage p, address m) internal view returns (bool) {
        uint256 n = p.nModules;
        for (uint256 i; i < n; ++i) {
            if (p.modules[i] == m) return true;
        }
        return false;
    }

    /// @dev Adds `amount` to this transaction's running buy (or sell) volume and swap count for the pool.
    ///      Transient storage: it resets at the end of every transaction.
    function _txAdd(PoolId id, bool isBuy, uint256 amount) internal returns (uint256 total) {
        bytes32 slot = keccak256(abi.encode(isBuy ? TX_BUY : TX_SELL, id));
        bytes32 cslot = keccak256(abi.encode(TX_SWAPS, id));
        assembly ("memory-safe") {
            total := add(tload(slot), amount)
            tstore(slot, total)
            tstore(cslot, add(tload(cslot), 1))
        }
    }

    function _txGet(PoolId id, bool isBuy) internal view returns (uint256 total) {
        bytes32 slot = keccak256(abi.encode(isBuy ? TX_BUY : TX_SELL, id));
        assembly ("memory-safe") {
            total := tload(slot)
        }
    }

    function _txSwaps(PoolId id) internal view returns (uint256 count) {
        bytes32 slot = keccak256(abi.encode(TX_SWAPS, id));
        assembly ("memory-safe") {
            count := tload(slot)
        }
    }

    function _payout(address account, Currency currency, address to) internal {
        uint256 amount = claimable[account][currency];
        if (amount == 0 || to == address(0)) revert NothingToClaim();
        claimable[account][currency] = 0;
        emit Claimed(account, currency, to, amount);
        // Plain balances (curve credits) first, then ERC-6909 claims. Token balances can only move once the
        // token has graduated (the transfer lock), so token claims earned on the curve wait for graduation.
        uint256 h = held[currency];
        uint256 fromHeld = h < amount ? h : amount;
        if (fromHeld > 0) {
            held[currency] = h - fromHeld;
            if (currency.isAddressZero()) {
                (bool ok,) = to.call{value: fromHeld}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(to, fromHeld);
            }
        }
        if (amount > fromHeld) poolManager.unlock(abi.encode(uint8(0), abi.encode(currency, to, amount - fromHeld)));
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
