// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title AutoLpModule
/// @notice "Auto-LP": `lpBps` of every buy's quote input and every sell's quote output is saved (as this
///         module's claim in the hook, per pool, on the bonding curve and in the pool alike). After graduation
///         anyone can call `compound`: it spends up to `maxSpend` of the savings, half buying the token through
///         `AvaxHookV2.moduleSwap`, and adds both sides to the pool as one full-range position owned by this
///         module. The module has no way to remove liquidity, so what it adds is locked forever, and every
///         compound also reinvests the fees that position earned since the last one.
///   Manipulation bounds (as BuybackModule, plus a spot check because anyone may call it):
///   - the reference is a pre-swap checkpoint at least `REF_MIN_AGE_BLOCKS` old (two rolling checkpoints
///     kept in `onBeforeSwap`, pool phase only);
///   - `compound` refuses unless spot is within ~2% of that reference, so a pump has to be held against
///     arbitrage for `REF_MIN_AGE_BLOCKS` blocks to move the price a compound trades and adds at;
///   - its buy moves the price at most 5% from spot or the reference, whichever is tighter;
///   - it runs once at least a tenth of `maxSpend` is saved, and at most once per `COOLDOWN_BLOCKS`.
///   The hook only pays a module's whole claim in a currency, and the quote claim is shared by every pool
///   this module serves, so the exact amount a compound needs is moved to `sweeper` (transferClaim) and
///   claimed from there. Savings ride the swap path, so a credit the hook scales down or drops is never
///   counted (LedgerModuleBase). Never refuses a trade: no BLOCKS_SELLS.
contract AutoLpModule is LedgerModuleBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct Config {
        uint16 lpBps; // 1 .. 500 (5%) of each buy's quote input and each sell's quote output
        uint96 maxSpend; // quote units per compound, > 0
    }

    struct Vault {
        uint16 lpBps;
        uint96 maxSpend;
        bool quoteIs0;
        uint64 lastBlock; // last compound
        address quote;
        address token;
        uint128 saved; // this pool's share of the module's quote claim in the hook
        uint120 unverified; // the last credit, not yet checked against the hook's books
        bool live; // set at registration so this slot is never fresh inside a gas-capped callback
        uint160 refSqrtPrice;
        uint64 refBlock;
        uint160 nextRefSqrtPrice;
        uint64 nextRefBlock;
        uint128 quoteHand; // held by this contract for the pool: leftovers a compound couldn't pair
        uint128 tokenHand;
        uint128 liquidity; // of the module's locked position in this pool
        uint128 totalQuoteAdded;
        uint128 totalTokenAdded;
    }

    uint16 public constant MAX_LP_BPS = 500;
    uint32 public constant COOLDOWN_BLOCKS = 30;
    /// @notice A compound's price bounds come from a pre-swap price at least this many blocks old.
    uint32 public constant REF_MIN_AGE_BLOCKS = 30;
    // sqrtPrice factors: √0.95 / √1.05 bound the compound's buy (5% move); √0.98 / √1.02 bound how far spot
    // may sit from the reference before a compound runs at all (2%).
    uint256 internal constant SQRT_PRICE_DOWN_BPS = 9_747;
    uint256 internal constant SQRT_PRICE_UP_BPS = 10_247;
    uint256 internal constant SPOT_DOWN_BPS = 9_899;
    uint256 internal constant SPOT_UP_BPS = 10_100;

    mapping(PoolId => Vault) internal _vaults;
    /// @notice Claims the exact quote a compound needs (the hook only pays a whole claim).
    AutoLpSweeper public immutable sweeper;

    event Compounded(PoolId indexed id, uint256 quoteAdded, uint256 tokenAdded, uint128 liquidity);
    event HandRescued(PoolId indexed id, address indexed to, uint256 quote, uint256 tokens);

    error NotConfigured();
    error CompoundNotReady();
    error OnlyPoolManager();

    constructor(address _hook) LedgerModuleBase(_hook) {
        sweeper = new AutoLpSweeper(_hook);
    }

    receive() external payable {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.lpBps == 0 || c.lpBps > MAX_LP_BPS || c.maxSpend == 0) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config) external override onlyHook {
        Vault storage v = _vaults[id];
        if (v.maxSpend != 0) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (v.lpBps, v.maxSpend) = (c.lpBps, c.maxSpend);
        (v.quote, v.token) = (quote, token);
        v.quoteIs0 = quote < token;
        v.live = true;
        _seed(quote);
    }

    /// @dev Rolls the reference checkpoints in the pool, and saves `lpBps` of each buy's quote input.
    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        Vault storage v = _vaults[ctx.poolId];
        if (ctx.phase == ModuleCaps.PHASE_POOL && block.number >= uint256(v.nextRefBlock) + REF_MIN_AGE_BLOCKS) {
            v.refSqrtPrice = v.nextRefSqrtPrice;
            v.refBlock = v.nextRefBlock;
            v.nextRefSqrtPrice = ctx.sqrtPriceX96;
            v.nextRefBlock = uint64(block.number);
        }
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _save(ctx.poolId, v, ctx.amountIn));
    }

    /// @dev Saves `lpBps` of each sell's quote output.
    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _save(ctx.poolId, _vaults[ctx.poolId], ctx.amountOut);
    }

    /// @notice Turns saved quote into locked full-range liquidity in the pool of `key`. Anyone, within the
    ///         price bounds and the cooldown above.
    function compound(PoolKey calldata key) external returns (uint256 quoteAdded, uint256 tokenAdded) {
        PoolId id = key.toId();
        Vault storage v = _vaults[id];
        if (v.maxSpend == 0 || address(key.hooks) != hook) revert NotConfigured();
        if (_openedAt(id) == 0) revert CompoundNotReady();
        if (v.lastBlock != 0 && block.number < uint256(v.lastBlock) + COOLDOWN_BLOCKS) revert CompoundNotReady();
        _reconcile();
        uint256 saved = v.saved;
        // Runs once a tenth of the per-run cap is saved, so dust can't be used to churn the pool.
        if (saved == 0 || saved * 10 < v.maxSpend) revert CompoundNotReady();
        uint256 budget = saved > v.maxSpend ? v.maxSpend : saved;

        // Half buys the token (credited to this module's claim), the rest is claimed as is.
        (uint256 spent, uint256 got) = AvaxHookV2(payable(hook)).moduleSwap(key, true, budget / 2, _limit(id, v), false);
        if (spent == 0 || got == 0) revert CompoundNotReady();
        _spent(v.quote, spent);
        uint256 rest = budget - spent;
        if (rest > 0) {
            _payClaim(v.quote, address(sweeper), rest);
            sweeper.pull(v.quote);
        }
        v.saved = uint128(saved - budget);
        v.quoteHand += uint128(rest);
        v.tokenHand += uint128(_claimTokens(v.token));

        (quoteAdded, tokenAdded) = _addLiquidity(key, id, v);
        v.lastBlock = uint64(block.number);
    }

    /// @notice After the registry disabled this module, pays what it holds for the pool of `token` (quote
    ///         and tokens it couldn't pair) to the pool's creator. Anyone. The pool's claim in the hook goes
    ///         the same way through `rescue`; the locked position stays locked.
    function rescueHand(address token) external {
        AvaxHookV2 h = AvaxHookV2(payable(hook));
        if (!h.disabled(address(this))) revert NotDisabled();
        PoolId id = h.poolOfToken(token);
        Vault storage v = _vaults[id];
        (uint256 q, uint256 t) = (v.quoteHand, v.tokenHand);
        (v.quoteHand, v.tokenHand) = (0, 0);
        address creator = h.poolInfo(id).creator;
        _send(Currency.wrap(v.quote), creator, q);
        _send(Currency.wrap(v.token), creator, t);
        emit HandRescued(id, creator, q, t);
    }

    // ---------------------------------------------------------------- views

    function vaultOf(PoolId id) external view returns (Vault memory) {
        return _vaults[id];
    }

    /// @notice The sqrtPrice a compound is bounded against: the newest pre-swap checkpoint that is at least
    ///         `REF_MIN_AGE_BLOCKS` old (0 before the pool has one).
    function compoundReference(PoolId id) public view returns (uint256) {
        Vault storage v = _vaults[id];
        if (v.nextRefSqrtPrice != 0 && block.number >= uint256(v.nextRefBlock) + REF_MIN_AGE_BLOCKS) {
            return v.nextRefSqrtPrice;
        }
        return v.refSqrtPrice;
    }

    // ---------------------------------------------------------------- liquidity

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        // The caller delta carries the position's fees earned since the last add: they come back here.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _addLiquidity(PoolKey calldata key, PoolId id, Vault storage v) internal returns (uint256 quoteAdded, uint256 tokenAdded) {
        uint160 sqrtP = _sqrtPrice(id);
        (uint256 a0, uint256 a1) = v.quoteIs0 ? (uint256(v.quoteHand), uint256(v.tokenHand)) : (uint256(v.tokenHand), uint256(v.quoteHand));
        // One wei short on each side: the pool rounds an add's amounts up.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing)),
            a0 > 0 ? a0 - 1 : 0,
            a1 > 0 ? a1 - 1 : 0
        );
        if (liquidity == 0) revert CompoundNotReady();
        BalanceDelta delta = abi.decode(poolManager.unlock(abi.encode(key, liquidity)), (BalanceDelta));
        (int128 dq, int128 dt) = v.quoteIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // Negative: paid into the position. Positive: fees collected back.
        uint256 q = uint256(v.quoteHand);
        uint256 t = uint256(v.tokenHand);
        if (dq < 0) quoteAdded = uint256(uint128(-dq));
        if (dt < 0) tokenAdded = uint256(uint128(-dt));
        q = q + (dq > 0 ? uint256(uint128(dq)) : 0) - quoteAdded;
        t = t + (dt > 0 ? uint256(uint128(dt)) : 0) - tokenAdded;
        (v.quoteHand, v.tokenHand) = (uint128(q), uint128(t));
        v.liquidity += liquidity;
        v.totalQuoteAdded += uint128(quoteAdded);
        v.totalTokenAdded += uint128(tokenAdded);
        emit Compounded(id, quoteAdded, tokenAdded, liquidity);
    }

    /// @dev Pays what the pool is owed (negative delta) or takes what it owes back (positive).
    function _settle(Currency c, int128 d) internal {
        if (d < 0) {
            uint256 amount = uint256(uint128(-d));
            if (c.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                poolManager.sync(c);
                IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), amount);
                poolManager.settle();
            }
        } else if (d > 0) {
            poolManager.take(c, address(this), uint256(uint128(d)));
        }
    }

    // ---------------------------------------------------------------- internals

    function _save(PoolId id, Vault storage v, uint256 quoteAmount) internal returns (Credit[] memory) {
        _reconcile();
        uint256 cut = (quoteAmount * v.lpBps) / BPS;
        if (cut == 0) return new Credit[](0);
        v.saved += uint128(cut);
        v.unverified += uint120(cut);
        _expect(id, v.quote, cut);
        return _one(address(this), cut);
    }

    /// @dev Claims the tokens a compound's buy credited to this module; returns how many arrived.
    function _claimTokens(address token) internal returns (uint256) {
        uint256 b0 = IERC20(token).balanceOf(address(this));
        AvaxHookV2(payable(hook)).claim(Currency.wrap(token), address(this));
        return IERC20(token).balanceOf(address(this)) - b0;
    }

    /// @dev Refuses unless spot sits within ~2% of the aged reference; then bounds the buy to a 5% move from
    ///      spot or the reference, whichever is tighter, in the direction a buy pushes the price.
    function _limit(PoolId id, Vault storage v) internal view returns (uint160) {
        uint256 ref = compoundReference(id);
        if (ref == 0) revert CompoundNotReady();
        uint256 spot = _sqrtPrice(id);
        if (spot < (ref * SPOT_DOWN_BPS) / BPS || spot > (ref * SPOT_UP_BPS) / BPS) revert CompoundNotReady();
        uint256 l;
        if (v.quoteIs0) {
            l = ((spot > ref ? spot : ref) * SQRT_PRICE_DOWN_BPS) / BPS;
            if (l >= spot) revert CompoundNotReady();
        } else {
            l = ((spot < ref ? spot : ref) * SQRT_PRICE_UP_BPS) / BPS;
            if (l <= spot) revert CompoundNotReady();
        }
        if (l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
        if (l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(l);
    }

    function _send(Currency c, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (c.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NotConfigured();
        } else {
            IERC20(Currency.unwrap(c)).safeTransfer(to, amount);
        }
    }

    function _takeShare(PoolId id) internal override returns (address, uint256 amount) {
        Vault storage v = _vaults[id];
        amount = v.saved;
        v.saved = 0;
        return (v.quote, amount);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Vault storage v = _vaults[id];
        return (v.quote, v.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Vault storage v = _vaults[id];
        v.saved = shortfall > v.saved ? 0 : v.saved - uint128(shortfall);
        v.unverified = 0;
    }
}

/// @notice Receives an exact slice of AutoLpModule's quote claim and claims it straight back to the module.
contract AutoLpSweeper {
    address public immutable module;
    address public immutable hook;

    error OnlyModule();

    constructor(address _hook) {
        module = msg.sender;
        hook = _hook;
    }

    function pull(address quote) external {
        if (msg.sender != module) revert OnlyModule();
        AvaxHookV2(payable(hook)).claim(Currency.wrap(quote), module);
    }
}
