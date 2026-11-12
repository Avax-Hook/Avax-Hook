// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {AvaxHookV2} from "./AvaxHookV2.sol";
import {HookTokenV2} from "./HookTokenV2.sol";
import {HookTokenFactoryV2} from "./HookTokenFactoryV2.sol";
import {ModuleCaps} from "./interfaces/IHookModule.sol";
import {QuoteRegistry} from "../QuoteRegistry.sol";

/// @title HookLaunchpadV2
/// @notice v1's launchpad (same curve, same live QuoteRegistry, same graduation into Uniswap v4 with a
///         locked full-range position) with a v2 hook: a launch names a list of registry modules and
///         their configs instead of one fixed config struct. The module list is frozen at launch.
///
///   Supply 1,000,000,000: 800M sold on the curve; up to 200M paired with the raise in the pool.
///   Curve-phase anti-snipe (per-block cap + snipe tax) stays here, as in v1.
///
///   Modules on the curve: every curve trade (buy, sell, dev buy, trusted-caller buy/sell) runs the pool's
///   swap modules through `hook.curveSwap`, before and after the trade, with pool semantics:
///   - Buys: before-credits come out of the quote input, after-credits out of the tokens bought. Modules
///     see `amountIn` = the whole input, or on the final buy the input that fills the rest of the curve
///     under the core fees; their before-cut and extra fee are then charged on top (from the refund), so
///     the curve still fills exactly, or the buy fills partly if the input can't cover them.
///   - Sells: before-credits come out of the tokens sold (only the rest is sold into the curve),
///     after-credits out of the gross quote output.
///   - extraFeePips: an extra cut of the gross quote (buy input / sell output), capped at 30%, added to
///     `bonus`, i.e. to the pool's liquidity at graduation (the curve's stand-in for the LP fee).
///   - Credited amounts move to the hook (claims), to 0x…dEaD (BURN), or for LP_DONATE: quote to `bonus`,
///     tokens burned. Trader identity is the real buyer/seller: msg.sender, or `to` on a trusted
///     caller's buyWithQuoteFor; `sellDeposited` names the trusted caller.
contract HookLaunchpadV2 is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    struct CurveGuard {
        uint32 guardBlocks; // curve-phase anti-snipe window (0 = off)
        uint96 maxBuyPerBlock; // cumulative quote buy cap per block during the window (0 = no cap)
        uint16 snipeTaxBps; // extra cut on guarded buys, added to the pool's liquidity at graduation
    }

    struct LaunchArgs {
        string name; // <= 32 bytes
        string symbol; // <= 12 bytes
        HookTokenV2.Metadata meta;
        address quote; // address(0) = native AVAX
        AvaxHookV2.CoreConfig core;
        CurveGuard guard;
        uint32[] moduleIds;
        bytes[] moduleConfigs;
        uint256 devBuy; // creator's first buy in quote units (for AVAX: msg.value - creationFee)
        uint256 minTokensOut;
    }

    struct Launch {
        address creator;
        address quote;
        uint16 creatorFeeBps;
        uint16 snipeTaxBps;
        uint64 createdAt;
        uint64 createdBlock;
        uint64 guardEndBlock;
        uint64 guardBlock;
        uint96 guardSpent;
        uint96 maxBuyPerBlock;
        uint128 target; // net quote that completes the curve
        uint128 virtualQuote; // x0
        uint128 virtualTokens; // y0
        uint128 reserve; // real quote in the curve
        uint128 tokensSold;
        uint128 bonus; // curve snipe tax, added to pool liquidity at graduation
        bool complete;
        bool graduated;
        uint128 positionLiquidity;
        uint16 caps; // OR of the modules' capabilities (frozen at launch)
    }

    // ---------------------------------------------------------------- constants

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant POOL_SUPPLY = 200_000_000 ether;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 public constant PROTOCOL_FEE_BPS = 30;
    uint32 public constant MAX_GUARD_BLOCKS = 7_200;
    uint16 public constant MAX_SNIPE_TAX_BPS = 2_500;
    /// @dev Gas a completing buy must carry so graduation can't be starved into deferral.
    uint256 internal constant GRADUATION_GAS = 700_000; // graduation itself costs ~310k warm, ~400k cold
    uint16 internal constant SWAP_CAPS = ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    uint256 internal constant PIPS = 1_000_000;

    // ---------------------------------------------------------------- storage

    IPoolManager public immutable poolManager;
    AvaxHookV2 public immutable hook;
    HookTokenFactoryV2 public immutable tokenFactory;
    QuoteRegistry public immutable registry;

    address public protocolRecipient;
    uint96 public creationFee; // always native AVAX
    bool public launchesPaused;

    address[] public tokens;
    mapping(address => Launch) internal _launches;
    mapping(address => address[]) internal _byCreator;
    /// @notice Owed balances: account => quote asset (address(0) = AVAX) => amount.
    mapping(address => mapping(address => uint256)) public claimable;
    /// @notice Contracts (StockOrders) allowed to buy for someone else and to sell deposited tokens.
    mapping(address => bool) public trustedCaller;
    /// @dev Tokens above a launch's curve inventory already here at its last curve trade (stray transfers):
    ///      they never count as a trusted caller's deposit in `sellDeposited`.
    mapping(address => uint256) internal _stray;

    // ---------------------------------------------------------------- events

    event TokenLaunched(
        address indexed token, address indexed creator, address indexed quote, string name, string symbol, string image, uint128 target, uint32[] moduleIds
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 reserve,
        uint256 tokensSold,
        uint256 priceWei
    );
    event CurveComplete(address indexed token);
    event Graduated(address indexed token, PoolId indexed poolId, uint160 sqrtPriceX96, uint256 quoteAmount, uint256 tokens, uint128 liquidity);
    event GraduationDeferred(address indexed token, bytes reason);
    event LpFeesCollected(address indexed token, uint256 toCreator, uint256 toProtocol, uint256 tokensBurned);
    event Claimed(address indexed account, address indexed quote, uint256 amount);
    event ConfigUpdated(address protocolRecipient, uint96 creationFee, bool paused);
    event TrustedCallerSet(address indexed caller, bool trusted);

    // ---------------------------------------------------------------- errors

    error Paused();
    error BadArgs();
    error UnknownToken();
    error CurveClosed();
    error NotGraduated();
    error Slippage();
    error MaxBuyExceeded(uint256 attempted, uint256 cap);
    error TransferFailed();
    error NothingToClaim();
    error OnlySelf();
    error OnlyPoolManager();
    error NeedMoreGas();
    error UnreachablePrice();
    error NotTrusted();

    constructor(
        IPoolManager _poolManager,
        AvaxHookV2 _hook,
        HookTokenFactoryV2 _tokenFactory,
        QuoteRegistry _registry,
        address _owner,
        address _protocolRecipient
    ) Ownable(_owner) {
        poolManager = _poolManager;
        hook = _hook;
        tokenFactory = _tokenFactory;
        registry = _registry;
        if (_protocolRecipient == address(0)) revert BadArgs();
        protocolRecipient = _protocolRecipient;
        creationFee = 0.05 ether;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    // ---------------------------------------------------------------- admin (never touches live launches)

    function setConfig(address _protocolRecipient, uint96 _creationFee, bool _paused) external onlyOwner {
        if (_protocolRecipient == address(0)) revert BadArgs();
        protocolRecipient = _protocolRecipient;
        creationFee = _creationFee;
        launchesPaused = _paused;
        emit ConfigUpdated(_protocolRecipient, _creationFee, _paused);
    }

    function setTrustedCaller(address caller, bool trusted) external onlyOwner {
        trustedCaller[caller] = trusted;
        emit TrustedCallerSet(caller, trusted);
    }

    // ---------------------------------------------------------------- launch

    function launch(LaunchArgs calldata a) external payable nonReentrant returns (address token) {
        if (launchesPaused) revert Paused();
        uint256 nameLen = bytes(a.name).length;
        uint256 symLen = bytes(a.symbol).length;
        if (nameLen == 0 || nameLen > 32 || symLen == 0 || symLen > 12) revert BadArgs();
        if (bytes(a.meta.description).length > 500 || bytes(a.meta.image).length > 300) revert BadArgs();
        if (a.guard.guardBlocks > MAX_GUARD_BLOCKS || a.guard.snipeTaxBps > MAX_SNIPE_TAX_BPS) revert BadArgs();
        hook.validateCore(a.core);
        QuoteRegistry.CurveParams memory cp = registry.curveParams(a.quote); // reverts if not allowed
        if (a.quote == address(0) ? msg.value != creationFee + a.devBuy : msg.value != creationFee) revert BadArgs();

        token = tokenFactory.create(a.name, a.symbol, a.meta, msg.sender, TOTAL_SUPPLY);

        Launch storage l = _launches[token];
        l.creator = msg.sender;
        l.quote = a.quote;
        l.creatorFeeBps = a.core.creatorFeeBps;
        l.snipeTaxBps = a.guard.snipeTaxBps;
        l.maxBuyPerBlock = a.guard.maxBuyPerBlock;
        l.createdAt = uint64(block.timestamp);
        l.createdBlock = uint64(block.number);
        l.guardEndBlock = a.guard.guardBlocks == 0 ? 0 : uint64(block.number + a.guard.guardBlocks);
        l.target = cp.target;
        l.virtualQuote = cp.virtualQuote;
        l.virtualTokens = cp.virtualTokens;
        // Refuse a launch whose graduation price v4 couldn't represent (v1 LP-1).
        {
            uint256 x1 = uint256(cp.virtualQuote) + cp.target;
            uint256 y1 = uint256(cp.virtualTokens) - CURVE_SUPPLY;
            uint256 tokensAtEnd = Math.min(POOL_SUPPLY, Math.mulDiv(cp.target, y1, x1));
            uint256 quoteAtEnd = Math.mulDiv(tokensAtEnd, x1, y1);
            if (a.quote < token) _sqrtPrice(quoteAtEnd, tokensAtEnd);
            else _sqrtPrice(tokensAtEnd, quoteAtEnd);
        }
        tokens.push(token);
        _byCreator[msg.sender].push(token);

        // Modules: resolved, validated and frozen by the hook (reverts on unknown/deprecated/conflicting).
        uint16 caps = hook.registerPool(poolKey(token), token, msg.sender, a.core, a.moduleIds, a.moduleConfigs);
        l.caps = caps;
        if (caps & ModuleCaps.ON_TRANSFER != 0) HookTokenV2(token).enableTransferRules();

        claimable[protocolRecipient][address(0)] += creationFee;
        emit TokenLaunched(token, msg.sender, a.quote, a.name, a.symbol, a.meta.image, cp.target, a.moduleIds);

        if (a.devBuy > 0) _buy(token, l, a.devBuy, a.minTokensOut, msg.sender, "");
    }

    // ---------------------------------------------------------------- curve trading

    /// @notice Buy on a curve quoted in native AVAX.
    function buy(address token, uint256 minTokensOut) external payable nonReentrant {
        Launch storage l = _launch(token);
        if (l.quote != address(0)) revert BadArgs();
        _buy(token, l, msg.value, minTokensOut, msg.sender, "");
    }

    /// @notice Buy on a curve quoted in an ERC-20 (approve this contract first).
    function buyWithQuote(address token, uint256 amountIn, uint256 minTokensOut) external {
        buyWithQuoteFor(token, amountIn, minTokensOut, msg.sender);
    }

    /// @notice Same, tokens to `to`. Buying for another address is reserved to trusted callers.
    function buyWithQuoteFor(address token, uint256 amountIn, uint256 minTokensOut, address to) public nonReentrant {
        if (to != msg.sender && !trustedCaller[msg.sender]) revert NotTrusted();
        Launch storage l = _launch(token);
        if (l.quote == address(0)) revert BadArgs();
        _buy(token, l, amountIn, minTokensOut, to, "");
    }

    /// @notice Buy naming a referrer and opaque per-trade data for the modules (`SwapContext.referrer`,
    ///         `.extra`, e.g. an allowlist proof). AVAX curves: send `amountIn` as value; ERC-20: approve.
    function buyWithData(address token, uint256 amountIn, uint256 minTokensOut, address referrer, bytes calldata extra)
        external
        payable
        nonReentrant
    {
        Launch storage l = _launch(token);
        if (l.quote == address(0) ? msg.value != amountIn : msg.value != 0) revert BadArgs();
        _buy(token, l, amountIn, minTokensOut, msg.sender, abi.encode(referrer, extra));
    }

    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant {
        _sell(token, tokenAmount, minQuoteOut, false, "");
    }

    /// @notice Sell with opaque per-trade data for the modules (`SwapContext.extra`).
    function sellWithData(address token, uint256 tokenAmount, uint256 minQuoteOut, bytes calldata extra) external nonReentrant {
        _sell(token, tokenAmount, minQuoteOut, false, abi.encode(address(0), extra));
    }

    /// @notice Curve sell of tokens the caller already sent here in the same transaction. Trusted callers only.
    function sellDeposited(address token, uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant {
        if (!trustedCaller[msg.sender]) revert NotTrusted();
        _sell(token, tokenAmount, minQuoteOut, true, "");
    }

    function _sell(address token, uint256 tokenAmount, uint256 minQuoteOut, bool deposited, bytes memory data) internal {
        Launch storage l = _launch(token);
        if (l.complete) revert CurveClosed();
        if (tokenAmount == 0) revert BadArgs();
        if (deposited && HookTokenV2(token).balanceOf(address(this)) < TOTAL_SUPPLY - l.tokensSold + _stray[token] + tokenAmount) {
            revert BadArgs();
        }

        // Modules before the trade: their credits come out of the tokens sold.
        AvaxHookV2.ModuleCuts memory mb;
        if (l.caps & SWAP_CAPS != 0) mb = hook.curveSwap(_trade(token, l, msg.sender, false, true, tokenAmount, 0, data));
        uint256 sold = tokenAmount - mb.cut;

        uint256 gross = Math.min(_quoteForTokens(l, sold), l.reserve);
        uint256 protocolFee = (gross * PROTOCOL_FEE_BPS) / BPS;
        uint256 creatorFee = (gross * l.creatorFeeBps) / BPS;
        uint256 extraFee = (gross * mb.extraFeePips) / PIPS;
        l.reserve -= uint128(gross);
        l.tokensSold -= uint128(sold);

        // Modules after the trade: their credits come out of the gross quote output.
        AvaxHookV2.ModuleCuts memory ma;
        if (l.caps & ModuleCaps.AFTER_SWAP != 0) {
            ma = hook.curveSwap(_trade(token, l, msg.sender, false, false, tokenAmount, gross, data));
        }
        uint256 out = gross - protocolFee - creatorFee - extraFee - ma.cut;
        if (out < minQuoteOut) revert Slippage();

        l.bonus += uint128(extraFee + ma.donated);
        claimable[l.creator][l.quote] += creatorFee;
        claimable[protocolRecipient][l.quote] += protocolFee;

        if (!deposited) HookTokenV2(token).curvePull(msg.sender, tokenAmount);
        _moveCut(token, mb, true);
        _moveCut(l.quote, ma, false);
        emit Trade(
            token, msg.sender, false, out, tokenAmount, gross - out, l.reserve, l.tokensSold, _spotPrice(l)
        );
        _pay(l.quote, msg.sender, out);
        _syncStray(token, l);
    }

    /// @dev Records the tokens held above the curve inventory, so only what arrives after a curve trade
    ///      (a trusted caller's deposit in the same transaction) can be sold by `sellDeposited`.
    function _syncStray(address token, Launch storage l) internal {
        uint256 bal = HookTokenV2(token).balanceOf(address(this));
        uint256 inv = TOTAL_SUPPLY - l.tokensSold;
        _stray[token] = bal > inv ? bal - inv : 0;
    }

    function _buy(address token, Launch storage l, uint256 amountIn, uint256 minTokensOut, address to, bytes memory data)
        internal
    {
        if (l.complete) revert CurveClosed();
        if (amountIn == 0) revert BadArgs();

        bool guard = l.guardEndBlock != 0 && block.number < l.guardEndBlock;
        uint256 keepBps = BPS - PROTOCOL_FEE_BPS - l.creatorFeeBps - (guard ? l.snipeTaxBps : 0);
        uint256 remaining = CURVE_SUPPLY - l.tokensSold;

        // `used`: the input the modules see. All of it, or on the final buy what filling the rest of the
        // curve costs under the core fees (the part filled on the curve).
        uint256 used = amountIn;
        bool last = _tokensForQuote(l, (amountIn * keepBps) / BPS) >= remaining;
        if (last) {
            uint256 x = l.virtualQuote + l.reserve;
            uint256 y = l.virtualTokens - l.tokensSold;
            uint256 netNeeded = Math.mulDiv(x, remaining, y - remaining, Math.Rounding.Ceil);
            used = Math.min(amountIn, Math.mulDiv(netNeeded, BPS, keepBps, Math.Rounding.Ceil));
        }

        // Modules before the trade: credits and extra fee come out of the quote input.
        AvaxHookV2.ModuleCuts memory mb;
        if (l.caps & SWAP_CAPS != 0) mb = hook.curveSwap(_trade(token, l, to, true, true, used, 0, data));
        uint256 moduleTake = mb.cut + (used * mb.extraFeePips) / PIPS;
        uint256 paid = used;
        // Final buy: the modules' take is charged on top (grossed up for the core fees), so the curve still
        // fills exactly; if the input can't cover it, the buy uses all of it and fills partly.
        if (last && moduleTake > 0) {
            paid = Math.min(amountIn, used + Math.mulDiv(moduleTake, BPS, keepBps, Math.Rounding.Ceil));
        }
        uint256 netCore = (paid * keepBps) / BPS;
        uint256 net = netCore - moduleTake;
        uint256 out = Math.min(_tokensForQuote(l, net), remaining);
        if (out == 0) revert Slippage();

        if (guard && l.maxBuyPerBlock != 0) {
            uint256 spent = l.guardBlock == block.number ? l.guardSpent : 0;
            uint256 total = spent + paid;
            if (total > l.maxBuyPerBlock) revert MaxBuyExceeded(total, l.maxBuyPerBlock);
            l.guardBlock = uint64(block.number);
            l.guardSpent = uint96(total);
        }

        if (l.quote != address(0)) _pull(l.quote, msg.sender, paid);

        uint256 protocolFee = (paid * PROTOCOL_FEE_BPS) / BPS;
        uint256 creatorFee = (paid * l.creatorFeeBps) / BPS;
        // snipe tax + the modules' extra fee + quote they donated: graduation liquidity
        l.bonus += uint128(paid - netCore - protocolFee - creatorFee + (moduleTake - mb.cut) + mb.donated);
        l.reserve += uint128(net);
        l.tokensSold += uint128(out);
        claimable[l.creator][l.quote] += creatorFee;
        claimable[protocolRecipient][l.quote] += protocolFee;
        _moveCut(l.quote, mb, false);

        // Modules after the trade: credits come out of the tokens bought.
        uint256 got = out;
        if (l.caps & ModuleCaps.AFTER_SWAP != 0) {
            AvaxHookV2.ModuleCuts memory ma = hook.curveSwap(_trade(token, l, to, true, false, used, out, data));
            got -= ma.cut;
            _moveCut(token, ma, true);
        }
        if (got < minTokensOut || got == 0) revert Slippage();

        if (!HookTokenV2(token).transfer(to, got)) revert TransferFailed();
        emit Trade(token, to, true, paid, got, paid - net, l.reserve, l.tokensSold, _spotPrice(l));
        _syncStray(token, l);

        if (l.tokensSold == CURVE_SUPPLY) {
            l.complete = true;
            emit CurveComplete(token);
            // Attempted atomically; the buy must carry enough gas so a caller can't starve the self-call
            // into deferral. If it still fails, the buy stands and anyone can retry `graduate`.
            if (gasleft() < GRADUATION_GAS) revert NeedMoreGas();
            try this.graduateFromBuy(token) {}
            catch (bytes memory reason) {
                emit GraduationDeferred(token, reason);
            }
        }
        if (l.quote == address(0) && amountIn > paid) _pay(address(0), msg.sender, amountIn - paid);
    }

    /// @dev One side of a curve trade for the hook, priced at the curve's current spot.
    function _trade(
        address token,
        Launch storage l,
        address trader,
        bool isBuy,
        bool before,
        uint256 amountIn,
        uint256 amountOut,
        bytes memory data
    ) internal view returns (AvaxHookV2.CurveTrade memory t) {
        t = AvaxHookV2.CurveTrade({
            token: token,
            quote: l.quote,
            sender: msg.sender,
            trader: trader,
            isBuy: isBuy,
            before: before,
            amountIn: amountIn,
            amountOut: amountOut,
            sqrtPriceX96: curveSqrtPrice(l.quote, token, l.virtualQuote + l.reserve, l.virtualTokens - l.tokensSold),
            data: data
        });
    }

    /// @dev Moves module credits taken from one side: claims to the hook, burns (and token donations) to
    ///      0x…dEaD. Quote donations were already added to `bonus`.
    function _moveCut(address asset, AvaxHookV2.ModuleCuts memory c, bool isToken) internal {
        if (c.held > 0) _pay(asset, address(hook), c.held);
        uint256 burn = c.burned + (isToken ? c.donated : 0);
        if (burn > 0) _pay(asset, DEAD, burn);
    }

    // ---------------------------------------------------------------- graduation

    function graduateFromBuy(address token) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _graduate(token);
    }

    function graduate(address token) external nonReentrant {
        _graduate(token);
    }

    function poolKey(address token) public view returns (PoolKey memory key) {
        address quote = _launch(token).quote;
        (address c0, address c1) = quote < token ? (quote, token) : (token, quote);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function poolId(address token) external view returns (PoolId) {
        return poolKey(token).toId();
    }

    function quoteOf(address token) external view returns (address) {
        return _launch(token).quote;
    }

    function _graduate(address token) internal {
        Launch storage l = _launch(token);
        if (!l.complete || l.graduated) revert CurveClosed();
        l.graduated = true;

        uint256 x1 = uint256(l.virtualQuote) + l.reserve;
        uint256 y1 = uint256(l.virtualTokens) - l.tokensSold;
        uint256 bonus = l.bonus;
        uint256 raised = uint256(l.reserve) + bonus;
        uint256 poolTokens = Math.mulDiv(raised, y1, x1);
        uint256 quoteAmount = raised;
        if (poolTokens > POOL_SUPPLY) {
            poolTokens = POOL_SUPPLY;
            quoteAmount = Math.mulDiv(POOL_SUPPLY, x1, y1);
        }
        l.reserve = 0;
        l.bonus = 0;

        PoolKey memory key = poolKey(token);
        bool quoteIs0 = Currency.unwrap(key.currency0) == l.quote;
        (uint256 amount0, uint256 amount1) = quoteIs0 ? (quoteAmount, poolTokens) : (poolTokens, quoteAmount);
        uint160 sqrtPriceX96 = _sqrtPrice(amount0, amount1);

        poolManager.initialize(key, sqrtPriceX96); // the hook opens the registered pool

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING)),
            amount0,
            amount1
        );
        l.positionLiquidity = liquidity;
        (uint256 paid0, uint256 paid1) =
            abi.decode(poolManager.unlock(abi.encode(uint8(0), key, int256(uint256(liquidity)))), (uint256, uint256));

        HookTokenV2(token).openTrading();
        uint256 tokenDust = HookTokenV2(token).balanceOf(address(this));
        if (tokenDust > 0) HookTokenV2(token).transfer(DEAD, tokenDust);
        (uint256 paidQuote, uint256 paidTokens) = quoteIs0 ? (paid0, paid1) : (paid1, paid0);
        if (raised > paidQuote) {
            // Quote the position couldn't take: the bonus-derived part (module extra fees, LP donations,
            // snipe tax, meant for the pool) goes to the creator, rounding dust to the protocol (M-2).
            uint256 excess = raised - paidQuote;
            uint256 toCreator = excess < bonus ? excess : bonus;
            if (toCreator > 0) claimable[l.creator][l.quote] += toCreator;
            if (excess > toCreator) claimable[protocolRecipient][l.quote] += excess - toCreator;
        }

        emit Graduated(token, key.toId(), sqrtPriceX96, paidQuote, paidTokens, liquidity);
    }

    /// @notice Collects the locked position's LP fees: quote side to the creator, token side burned.
    function collectLpFees(address token) external nonReentrant {
        Launch storage l = _launch(token);
        if (!l.graduated) revert NotGraduated();
        PoolKey memory key = poolKey(token);
        (uint256 fee0, uint256 fee1) =
            abi.decode(poolManager.unlock(abi.encode(uint8(1), key, int256(0))), (uint256, uint256));
        bool quoteIs0 = Currency.unwrap(key.currency0) == l.quote;
        (uint256 quoteFees, uint256 tokenFees) = quoteIs0 ? (fee0, fee1) : (fee1, fee0);
        claimable[l.creator][l.quote] += quoteFees;
        emit LpFeesCollected(token, quoteFees, 0, tokenFees);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint8 action, PoolKey memory key, int256 liquidityDelta) = abi.decode(data, (uint8, PoolKey, int256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (action == 0) {
            uint256 owe0 = uint256(uint128(-d0));
            uint256 owe1 = uint256(uint128(-d1));
            _settle(key.currency0, owe0);
            _settle(key.currency1, owe1);
            return abi.encode(owe0, owe1);
        }
        address token = _isLaunchToken(key.currency0) ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        uint256 fee0 = d0 > 0 ? uint256(uint128(d0)) : 0;
        uint256 fee1 = d1 > 0 ? uint256(uint128(d1)) : 0;
        if (fee0 > 0) poolManager.take(key.currency0, Currency.unwrap(key.currency0) == token ? DEAD : address(this), fee0);
        if (fee1 > 0) poolManager.take(key.currency1, Currency.unwrap(key.currency1) == token ? DEAD : address(this), fee1);
        return abi.encode(fee0, fee1);
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _isLaunchToken(Currency c) internal view returns (bool) {
        return _launches[Currency.unwrap(c)].creator != address(0);
    }

    // ---------------------------------------------------------------- claims

    function claim(address quote) external {
        claimTo(quote, msg.sender);
    }

    function claimTo(address quote, address to) public nonReentrant {
        uint256 amount = claimable[msg.sender][quote];
        if (amount == 0 || to == address(0)) revert NothingToClaim();
        claimable[msg.sender][quote] = 0;
        emit Claimed(msg.sender, quote, amount);
        _pay(quote, to, amount);
    }

    // ---------------------------------------------------------------- views

    function getLaunch(address token) external view returns (Launch memory) {
        return _launch(token);
    }

    function launchCount() external view returns (uint256) {
        return tokens.length;
    }

    function launchesByCreator(address creator) external view returns (address[] memory) {
        return _byCreator[creator];
    }

    // ---------------------------------------------------------------- internals

    function _launch(address token) internal view returns (Launch storage l) {
        l = _launches[token];
        if (l.creator == address(0)) revert UnknownToken();
    }

    function _tokensForQuote(Launch storage l, uint256 net) internal view returns (uint256) {
        uint256 x = l.virtualQuote + l.reserve;
        uint256 y = l.virtualTokens - l.tokensSold;
        return Math.mulDiv(y, net, x + net);
    }

    function _quoteForTokens(Launch storage l, uint256 amount) internal view returns (uint256) {
        uint256 x = l.virtualQuote + l.reserve;
        uint256 y = l.virtualTokens - l.tokensSold;
        return Math.mulDiv(x, amount, y + amount);
    }

    /// @notice The curve price `x` quote per `y` tokens as a v4 sqrtPriceX96 in the pool's orientation, so
    ///         modules price the curve exactly like the pool (market cap helpers etc.).
    function curveSqrtPrice(address quote, address token, uint256 x, uint256 y) public pure returns (uint160) {
        return quote < token ? _sqrtPrice(x, y) : _sqrtPrice(y, x);
    }

    function _spotPrice(Launch storage l) internal view returns (uint256) {
        if (l.complete) return Math.mulDiv(uint256(l.virtualQuote) + l.target, 1e36, l.virtualTokens - CURVE_SUPPLY);
        return Math.mulDiv(l.virtualQuote + l.reserve, 1e36, l.virtualTokens - l.tokensSold);
    }

    /// @dev sqrt(amount1 / amount0) in Q64.96 without overflowing for large ratios (v1 LP-1 fix).
    function _sqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) revert UnreachablePrice();
        uint256 s;
        if (amount1 / amount0 < (1 << 64)) {
            s = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        } else {
            if (amount1 / amount0 >= (1 << 128)) revert UnreachablePrice();
            s = Math.sqrt(Math.mulDiv(amount1, 1 << 128, amount0)) << 32;
        }
        if (s < TickMath.MIN_SQRT_PRICE || s >= TickMath.MAX_SQRT_PRICE) revert UnreachablePrice();
        return uint160(s);
    }

    /// @dev Pulls exactly `amount`; reverts on fee-on-transfer or otherwise short transfers.
    function _pull(address quote, address from, uint256 amount) internal {
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(from, address(this), amount);
        if (IERC20(quote).balanceOf(address(this)) - before != amount) revert TransferFailed();
    }

    function _pay(address quote, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }
}
