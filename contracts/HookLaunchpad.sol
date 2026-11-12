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

import {AvaxHook} from "./AvaxHook.sol";
import {HookToken} from "./HookToken.sol";
import {HookTokenFactory} from "./HookTokenFactory.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";

/// @title HookLaunchpad
/// @notice Launches a fixed-supply token on a constant-product bonding curve priced in a quote
///         asset the creator picks from an allowlist: native AVAX, USDC, or a tokenized stock.
///         When the curve sells out, the raise and the reserved supply open a Uniswap v4
///         quote/token pool with the creator's hooks attached. That liquidity is a full-range
///         position owned by this contract with no remove path: locked forever.
///
///   Supply 1,000,000,000: 800M sold on the curve; up to 200M paired with the raise in the pool.
///   Curve: x·y = k on virtual reserves set by the QuoteRegistry so every launch starts at the same
///   USD market cap and graduates at the same USD market cap (defaults $2.5k → $50k), converted to
///   the chosen quote at launch and then frozen. The pool opens at exactly the curve's last price:
///   raise / lastPrice tokens go in, any of the reserved 200M left over is burned.
///   Anti-snipe applies twice: at curve open (this contract) and at pool open (the hook).
contract HookLaunchpad is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    struct LaunchArgs {
        string name; // <= 32 bytes
        string symbol; // <= 12 bytes
        HookToken.Metadata meta;
        address quote; // address(0) = native AVAX
        uint32 blueprintId; // 0 = use `hook` below
        AvaxHook.HookConfig hook;
        uint256 devBuy; // creator's first buy in quote units (for AVAX: msg.value - creationFee)
        uint256 minTokensOut;
    }

    struct Launch {
        address creator;
        address quote;
        uint32 blueprintId;
        uint64 createdAt;
        uint64 createdBlock;
        uint64 guardEndBlock; // curve-phase anti-snipe
        uint64 guardBlock;
        uint96 guardSpent;
        uint128 target; // net quote that completes the curve
        uint128 virtualQuote; // x0
        uint128 virtualTokens; // y0
        uint128 reserve; // real quote in the curve
        uint128 tokensSold;
        uint128 bonus; // curve snipe tax, added to pool liquidity at graduation
        bool complete;
        bool graduated;
        uint128 positionLiquidity;
        AvaxHook.HookConfig hook;
    }

    struct Blueprint {
        address author;
        uint16 royaltyBps; // share of the creator's curve fee paid to the author, <= 2000
        uint32 uses;
        string name;
        AvaxHook.HookConfig hook;
    }

    // ---------------------------------------------------------------- constants

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant POOL_SUPPLY = 200_000_000 ether;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Fixed protocol fee on curve trades; the creator adds their own fee (hook.creatorFeeBps,
    ///         up to 10%) on top. The same 0.3% applies in the pool through the hook.
    uint16 public constant PROTOCOL_FEE_BPS = 30;
    uint16 internal constant MAX_ROYALTY_BPS = 2_000;
    /// @dev Gas a completing buy must carry so graduation can't be starved into deferral.
    uint256 internal constant GRADUATION_GAS = 600_000; // graduation itself costs ~480-500k

    // ---------------------------------------------------------------- storage

    IPoolManager public immutable poolManager;
    AvaxHook public immutable hook;
    HookTokenFactory public immutable tokenFactory;
    QuoteRegistry public immutable registry;

    address public protocolRecipient;
    uint96 public creationFee; // always native AVAX
    bool public launchesPaused;

    address[] public tokens;
    mapping(address => Launch) internal _launches;
    mapping(address => address[]) internal _byCreator;
    Blueprint[] internal _blueprints; // index 0 is a placeholder
    /// @notice Owed balances: account => quote asset (address(0) = AVAX) => amount.
    mapping(address => mapping(address => uint256)) public claimable;
    /// @notice Contracts (StockOrders) allowed to buy for someone else and to sell deposited tokens.
    ///         Anyone else could route curve-phase tokens into a contract that credits balances on
    ///         receipt (the v4 PoolManager's settle → ERC-6909 claims) and trade them pre-graduation.
    mapping(address => bool) public trustedCaller;

    // ---------------------------------------------------------------- events

    event TokenLaunched(
        address indexed token, address indexed creator, address indexed quote, uint32 blueprintId, string name, string symbol, string image, uint128 target
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
    event BlueprintSaved(uint32 indexed id, address indexed author, string name, uint16 royaltyBps);
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
        AvaxHook _hook,
        HookTokenFactory _tokenFactory,
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
        _blueprints.push();
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

    // ---------------------------------------------------------------- blueprints

    function saveBlueprint(string calldata name, AvaxHook.HookConfig calldata cfg, uint16 royaltyBps)
        external
        returns (uint32 id)
    {
        if (bytes(name).length == 0 || bytes(name).length > 48 || royaltyBps > MAX_ROYALTY_BPS) revert BadArgs();
        hook.validateConfig(cfg);
        id = uint32(_blueprints.length);
        _blueprints.push(Blueprint({author: msg.sender, royaltyBps: royaltyBps, uses: 0, name: name, hook: cfg}));
        emit BlueprintSaved(id, msg.sender, name, royaltyBps);
    }

    // ---------------------------------------------------------------- launch

    function launch(LaunchArgs calldata a) external payable nonReentrant returns (address token) {
        if (launchesPaused) revert Paused();
        uint256 nameLen = bytes(a.name).length;
        uint256 symLen = bytes(a.symbol).length;
        if (nameLen == 0 || nameLen > 32 || symLen == 0 || symLen > 12) revert BadArgs();
        if (bytes(a.meta.description).length > 500 || bytes(a.meta.image).length > 300) revert BadArgs();
        QuoteRegistry.CurveParams memory cp = registry.curveParams(a.quote); // reverts if not allowed
        bool native = a.quote == address(0);
        if (native ? msg.value != creationFee + a.devBuy : msg.value != creationFee) revert BadArgs();

        AvaxHook.HookConfig memory cfg = a.hook;
        if (a.blueprintId != 0) {
            if (a.blueprintId >= _blueprints.length) revert BadArgs();
            Blueprint storage bp = _blueprints[a.blueprintId];
            cfg = bp.hook;
            bp.uses += 1;
        }
        hook.validateConfig(cfg);

        token = tokenFactory.create(a.name, a.symbol, a.meta, msg.sender, TOTAL_SUPPLY);

        Launch storage l = _launches[token];
        l.creator = msg.sender;
        l.quote = a.quote;
        l.blueprintId = a.blueprintId;
        l.createdAt = uint64(block.timestamp);
        l.createdBlock = uint64(block.number);
        l.guardEndBlock = cfg.guardBlocks == 0 ? 0 : uint64(block.number + cfg.guardBlocks);
        l.target = cp.target;
        l.virtualQuote = cp.virtualQuote;
        l.virtualTokens = cp.virtualTokens;
        // Refuse a launch whose graduation price v4 couldn't represent (e.g. a quote whose single
        // unit is worth a lot): otherwise the curve could fill and then never graduate.
        {
            uint256 x1 = uint256(cp.virtualQuote) + cp.target;
            uint256 y1 = uint256(cp.virtualTokens) - CURVE_SUPPLY;
            uint256 tokensAtEnd = Math.min(POOL_SUPPLY, Math.mulDiv(cp.target, y1, x1));
            uint256 quoteAtEnd = Math.mulDiv(tokensAtEnd, x1, y1);
            if (a.quote < token) _sqrtPrice(quoteAtEnd, tokensAtEnd);
            else _sqrtPrice(tokensAtEnd, quoteAtEnd);
        }
        l.hook = cfg;
        tokens.push(token);
        _byCreator[msg.sender].push(token);

        claimable[protocolRecipient][address(0)] += creationFee;
        emit TokenLaunched(token, msg.sender, a.quote, a.blueprintId, a.name, a.symbol, a.meta.image, cp.target);

        if (a.devBuy > 0) _buy(token, l, a.devBuy, a.minTokensOut, msg.sender);
    }

    // ---------------------------------------------------------------- curve trading

    /// @notice Buy on a curve quoted in native AVAX.
    function buy(address token, uint256 minTokensOut) external payable nonReentrant {
        Launch storage l = _launch(token);
        if (l.quote != address(0)) revert BadArgs();
        _buy(token, l, msg.value, minTokensOut, msg.sender);
    }

    /// @notice Buy on a curve quoted in an ERC-20 (approve this contract first).
    function buyWithQuote(address token, uint256 amountIn, uint256 minTokensOut) external {
        buyWithQuoteFor(token, amountIn, minTokensOut, msg.sender);
    }

    /// @notice Same, but the tokens go to `to` (curve-phase tokens can't be forwarded afterwards).
    ///         The quote is pulled from the caller; an unused remainder is never pulled. Buying for
    ///         another address is reserved to trusted callers.
    function buyWithQuoteFor(address token, uint256 amountIn, uint256 minTokensOut, address to) public nonReentrant {
        if (to != msg.sender && !trustedCaller[msg.sender]) revert NotTrusted();
        Launch storage l = _launch(token);
        if (l.quote == address(0)) revert BadArgs(); // to == 0 reverts in the ERC-20 transfer
        _buy(token, l, amountIn, minTokensOut, to);
    }

    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant {
        _sell(token, tokenAmount, minQuoteOut, false);
    }

    /// @notice Curve sell of tokens the caller already sent to this contract in the same transaction
    ///         (curve-phase tokens may move to the launchpad, so a contract holding a holder's approval
    ///         can sell for them). Anything above the curve's own balance counts as deposited, so only
    ///         trusted callers may sell it.
    function sellDeposited(address token, uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant {
        if (!trustedCaller[msg.sender]) revert NotTrusted();
        _sell(token, tokenAmount, minQuoteOut, true);
    }

    function _sell(address token, uint256 tokenAmount, uint256 minQuoteOut, bool deposited) internal {
        Launch storage l = _launch(token);
        if (l.complete) revert CurveClosed();
        if (tokenAmount == 0) revert BadArgs();
        if (deposited && HookToken(token).balanceOf(address(this)) < TOTAL_SUPPLY - l.tokensSold + tokenAmount) revert BadArgs();

        uint256 gross = Math.min(_quoteForTokens(l, tokenAmount), l.reserve);
        uint256 protocolFee = (gross * PROTOCOL_FEE_BPS) / BPS;
        uint256 creatorFee = (gross * l.hook.creatorFeeBps) / BPS;
        uint256 fee = protocolFee + creatorFee;
        uint256 out = gross - fee;
        if (out < minQuoteOut) revert Slippage();

        l.reserve -= uint128(gross);
        l.tokensSold -= uint128(tokenAmount);
        _splitTradeFee(l, protocolFee, creatorFee);

        if (!deposited) HookToken(token).curvePull(msg.sender, tokenAmount);
        emit Trade(token, msg.sender, false, out, tokenAmount, fee, l.reserve, l.tokensSold, _spotPrice(l));
        _pay(l.quote, msg.sender, out);
    }

    function _buy(address token, Launch storage l, uint256 amountIn, uint256 minTokensOut, address to) internal {
        if (l.complete) revert CurveClosed();
        if (amountIn == 0) revert BadArgs();

        bool guard = l.guardEndBlock != 0 && block.number < l.guardEndBlock;
        uint256 feeBps = PROTOCOL_FEE_BPS + l.hook.creatorFeeBps;
        uint256 keepBps = BPS - feeBps - (guard ? l.hook.snipeTaxBps : 0);

        uint256 net = (amountIn * keepBps) / BPS;
        uint256 out = _tokensForQuote(l, net);
        uint256 remaining = CURVE_SUPPLY - l.tokensSold;
        uint256 used = amountIn;
        if (out >= remaining) {
            // Final buy: fill exactly the rest of the curve and charge only what that costs.
            out = remaining;
            uint256 x = l.virtualQuote + l.reserve;
            uint256 y = l.virtualTokens - l.tokensSold;
            net = Math.mulDiv(x, remaining, y - remaining, Math.Rounding.Ceil);
            used = Math.min(amountIn, Math.mulDiv(net, BPS, keepBps, Math.Rounding.Ceil));
            net = (used * keepBps) / BPS;
        }
        if (out < minTokensOut || out == 0) revert Slippage();

        if (guard && l.hook.maxBuyPerBlock != 0) {
            uint256 spent = l.guardBlock == block.number ? l.guardSpent : 0;
            uint256 total = spent + used;
            if (total > l.hook.maxBuyPerBlock) revert MaxBuyExceeded(total, l.hook.maxBuyPerBlock);
            l.guardBlock = uint64(block.number);
            l.guardSpent = uint96(total);
        }

        // Collect the quote: native arrives with the call, ERC-20s are pulled for exactly `used`.
        if (l.quote != address(0)) _pull(l.quote, msg.sender, used);

        uint256 protocolFee = (used * PROTOCOL_FEE_BPS) / BPS;
        uint256 creatorFee = (used * l.hook.creatorFeeBps) / BPS;
        uint256 fee = protocolFee + creatorFee;
        uint256 tax = used - net - fee;
        l.reserve += uint128(net);
        l.tokensSold += uint128(out);
        l.bonus += uint128(tax);
        _splitTradeFee(l, protocolFee, creatorFee);

        if (!HookToken(token).transfer(to, out)) revert TransferFailed();
        emit Trade(token, to, true, used, out, fee + tax, l.reserve, l.tokensSold, _spotPrice(l));

        if (l.tokensSold == CURVE_SUPPLY) {
            l.complete = true;
            emit CurveComplete(token);
            // Attempted atomically. The buy must carry enough gas, so a caller can't starve the
            // self-call into deferral; if it still fails, the buy stands and anyone can retry `graduate`.
            if (gasleft() < GRADUATION_GAS) revert NeedMoreGas();
            try this.graduateFromBuy(token) {}
            catch (bytes memory reason) {
                emit GraduationDeferred(token, reason);
            }
        }
        if (l.quote == address(0) && amountIn > used) _pay(address(0), msg.sender, amountIn - used);
    }

    /// @dev The blueprint royalty comes out of the creator's fee, never the fixed protocol fee.
    function _splitTradeFee(Launch storage l, uint256 toProtocol, uint256 toCreator) internal {
        address q = l.quote;
        if (l.blueprintId != 0) {
            Blueprint storage bp = _blueprints[l.blueprintId];
            uint256 royalty = (toCreator * bp.royaltyBps) / BPS;
            claimable[bp.author][q] += royalty;
            toCreator -= royalty;
        }
        claimable[l.creator][q] += toCreator;
        claimable[protocolRecipient][q] += toProtocol;
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
        uint256 raised = uint256(l.reserve) + l.bonus;
        // Pair the raise with tokens at the curve's last price x1/y1, at most the 200M reserved. If a
        // large snipe-tax bonus would need more than 200M, the pool keeps the curve price and the
        // excess quote goes to the protocol instead of lifting the opening price.
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

        hook.configurePool(key, token, l.creator, protocolRecipient, l.hook);
        poolManager.initialize(key, sqrtPriceX96);

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

        HookToken(token).openTrading();
        // Tokens not needed in the pool (and rounding dust) are burned; leftover quote goes to the protocol.
        uint256 tokenDust = HookToken(token).balanceOf(address(this));
        if (tokenDust > 0) HookToken(token).transfer(DEAD, tokenDust);
        (uint256 paidQuote, uint256 paidTokens) = quoteIs0 ? (paid0, paid1) : (paid1, paid0);
        if (raised > paidQuote) claimable[protocolRecipient][l.quote] += raised - paidQuote;

        emit Graduated(token, key.toId(), sqrtPriceX96, paidQuote, paidTokens, liquidity);
    }

    /// @notice Collects the locked position's LP fees. The quote side goes to the creator (the
    ///         protocol already took its fixed 0.3% on each trade), the token side is burned.
    ///         Permissionless.
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
        // collect fees: credits; the token side goes straight to 0xdead
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

    /// @notice Withdraw what this contract owes you in one quote asset (address(0) = AVAX).
    function claim(address quote) external {
        claimTo(quote, msg.sender);
    }

    /// @notice Same, paid to `to` (for accounts that can't receive native AVAX themselves).
    function claimTo(address quote, address to) public nonReentrant {
        uint256 amount = claimable[msg.sender][quote];
        if (amount == 0 || to == address(0)) revert NothingToClaim();
        claimable[msg.sender][quote] = 0;
        emit Claimed(msg.sender, quote, amount);
        _pay(quote, to, amount);
    }

    // ---------------------------------------------------------------- views (more in HookLens)

    function getLaunch(address token) external view returns (Launch memory) {
        return _launch(token);
    }

    function launchCount() external view returns (uint256) {
        return tokens.length;
    }

    function getBlueprint(uint32 id) external view returns (Blueprint memory) {
        return _blueprints[id];
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

    /// @dev Marginal price of 1e18 tokens in quote units, scaled by 1e18 so 6-decimal quotes keep
    ///      precision. Once complete this is the curve's last price, which is the pool's opening price.
    function _spotPrice(Launch storage l) internal view returns (uint256) {
        // After graduation the reserve is zeroed; the curve's last price is x0 + target over y0 − 800M.
        if (l.complete) return Math.mulDiv(uint256(l.virtualQuote) + l.target, 1e36, l.virtualTokens - CURVE_SUPPLY);
        return Math.mulDiv(l.virtualQuote + l.reserve, 1e36, l.virtualTokens - l.tokensSold);
    }

    /// @dev sqrt(amount1 / amount0) in Q64.96 without overflowing for large ratios; reverts if the
    ///      price is outside what Uniswap v4 can represent.
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
