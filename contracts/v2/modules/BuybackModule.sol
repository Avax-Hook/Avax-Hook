// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title BuybackModule
/// @notice v1 "Buyback & burn": `buybackBps` of every pool sell's quote output is saved (as this module's claim
///         in the hook, per pool). The keeper spends the savings buying the token back through
///         `AvaxHookV2.moduleSwap` and burns what it buys, at most `maxSpend` per run.
///   Manipulation bounds kept from v1 (HK-2 / M-1, L-1):
///   - keeper-only (or the owner): nobody can trigger it right after their own pump;
///   - the price limit comes from a pre-swap checkpoint at least `REF_MIN_AGE_BLOCKS` old (two rolling
///     checkpoints kept in `onBeforeSwap`), and from spot, whichever is tighter. A buyback moves the price at
///     most 5% (sqrtPrice × √1.05 / √0.95, sqrt-correct); if spot already sits past that bound (a recent
///     pump) there is nothing to buy;
///   - it runs once at least a tenth of `maxSpend` is saved (dust can't churn the pool) and at most once per
///     `BUYBACK_COOLDOWN_BLOCKS`; a dust swap in the same block doesn't block it.
///   Sell savings ride the sell path, so if the hook scales them down (over the module cut cap) or drops
///   them (a failed isolated call), the shortfall is never counted (LedgerModuleBase). Never refuses sells: no BLOCKS_SELLS. Pool phase only: curve sells
///   save nothing and curve prices never become references.
contract BuybackModule is LedgerModuleBase, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    struct Config {
        uint16 buybackBps; // 1 .. 1,000 (10%) of each sell's quote output; with the core creator fee <= 1,500
        uint96 maxSpend; // quote units per buyback, > 0
    }

    struct Vault {
        uint16 buybackBps;
        uint96 maxSpend;
        bool quoteIs0;
        uint64 lastBlock; // last buyback
        address quote;
        uint128 saved; // this pool's share of the module's claim
        uint120 unverified; // the last sell's savings, not yet checked against the hook's books
        bool live; // set at registration so this slot is never fresh inside a gas-capped callback
        // two rolling checkpoints of the pre-swap sqrtPrice: `next` is taken at the first swap once the
        // previous one is REF_MIN_AGE_BLOCKS old, and then becomes `ref`
        uint160 refSqrtPrice;
        uint64 refBlock;
        uint160 nextRefSqrtPrice;
        uint64 nextRefBlock;
        uint128 totalSpent;
        uint128 totalBurned;
    }

    uint16 public constant MAX_BUYBACK_BPS = 1_000;
    uint16 public constant MAX_SELL_CUT_BPS = 1_500; // v1: creator fee + buyback
    uint32 public constant BUYBACK_COOLDOWN_BLOCKS = 30;
    /// @notice A buyback's price bound comes from a pre-swap price at least this many blocks old.
    uint32 public constant REF_MIN_AGE_BLOCKS = 30;
    // √0.95 ≈ 0.9747, √1.05 ≈ 1.0247: a 5% price move in sqrtPrice terms
    uint256 internal constant SQRT_PRICE_DOWN_BPS = 9_747;
    uint256 internal constant SQRT_PRICE_UP_BPS = 10_247;

    mapping(PoolId => Vault) internal _vaults;
    /// @notice The only account besides the owner that may run buybacks.
    address public keeper;

    event KeeperSet(address keeper);
    event BuybackBurn(PoolId indexed id, uint256 spent, uint256 tokensBurned);

    error NotKeeper();
    error NotConfigured();
    error BuybackNotReady();

    constructor(address _hook) LedgerModuleBase(_hook) Ownable(msg.sender) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.buybackBps == 0 || c.buybackBps > MAX_BUYBACK_BPS || c.maxSpend == 0) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config) external override onlyHook {
        Vault storage v = _vaults[id];
        if (v.maxSpend != 0) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        if (uint256(AvaxHookV2(payable(hook)).poolInfo(id).creatorFeeBps) + c.buybackBps > MAX_SELL_CUT_BPS) revert BadConfig();
        (v.buybackBps, v.maxSpend) = (c.buybackBps, c.maxSpend);
        v.quote = quote;
        v.live = true;
        _seed(quote);
        v.quoteIs0 = quote < token;
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    /// @dev Rolls the reference checkpoints (writes once per REF_MIN_AGE_BLOCKS window).
    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.phase == ModuleCaps.PHASE_CURVE) return (0, new Credit[](0)); // curve prices aren't pool references
        Vault storage v = _vaults[ctx.poolId];
        if (block.number >= uint256(v.nextRefBlock) + REF_MIN_AGE_BLOCKS) {
            v.refSqrtPrice = v.nextRefSqrtPrice;
            v.refBlock = v.nextRefBlock;
            v.nextRefSqrtPrice = ctx.sqrtPriceX96;
            v.nextRefBlock = uint64(block.number);
        }
        return (0, new Credit[](0));
    }

    /// @dev Sells: saves `buybackBps` of the quote output as this module's claim.
    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy || ctx.phase == ModuleCaps.PHASE_CURVE) return new Credit[](0);
        _reconcile();
        Vault storage v = _vaults[ctx.poolId];
        uint256 cut = (ctx.amountOut * v.buybackBps) / BPS;
        if (cut == 0) return new Credit[](0);
        v.saved += uint128(cut);
        v.unverified += uint120(cut);
        _expect(ctx.poolId, v.quote, cut);
        return _one(address(this), cut);
    }

    /// @notice Spends saved funds (up to `maxSpend`) buying the token and burns it. Keeper or owner only.
    function executeBuyback(PoolKey calldata key) external returns (uint256 spent, uint256 burned) {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        PoolId id = key.toId();
        Vault storage v = _vaults[id];
        if (v.maxSpend == 0 || address(key.hooks) != hook) revert NotConfigured();
        _reconcile();
        uint256 saved = v.saved;
        // Runs once a tenth of the per-run cap is saved, so dust can't be used to churn the pool.
        if (saved == 0 || saved * 10 < v.maxSpend) revert BuybackNotReady();
        if (v.lastBlock != 0 && block.number < uint256(v.lastBlock) + BUYBACK_COOLDOWN_BLOCKS) revert BuybackNotReady();
        uint256 budget = saved > v.maxSpend ? v.maxSpend : saved;

        uint160 limit = _limit(id, v);
        (spent, burned) = AvaxHookV2(payable(hook)).moduleSwap(key, true, budget, limit, true);
        if (spent == 0 || burned == 0) revert BuybackNotReady();
        _spent(v.quote, spent);
        v.saved = uint128(saved - spent);
        v.lastBlock = uint64(block.number);
        v.totalSpent += uint128(spent);
        v.totalBurned += uint128(burned);
        emit BuybackBurn(id, spent, burned);
    }

    // ---------------------------------------------------------------- views

    function vaultOf(PoolId id) external view returns (Vault memory) {
        return _vaults[id];
    }

    /// @notice The sqrtPrice a buyback is bounded against: the newest pre-swap checkpoint that is at least
    ///         `REF_MIN_AGE_BLOCKS` old (0 before the pool has one).
    function buybackReference(PoolId id) public view returns (uint256) {
        Vault storage v = _vaults[id];
        if (v.nextRefSqrtPrice != 0 && block.number >= uint256(v.nextRefBlock) + REF_MIN_AGE_BLOCKS) {
            return v.nextRefSqrtPrice;
        }
        return v.refSqrtPrice;
    }

    // ---------------------------------------------------------------- internals

    /// @dev 5% move from spot and from the aged reference, whichever is tighter, in the direction a buy
    ///      pushes the price (down when the quote is currency0, up otherwise).
    function _limit(PoolId id, Vault storage v) internal view returns (uint160) {
        uint256 ref = buybackReference(id);
        if (ref == 0) revert BuybackNotReady();
        uint256 sqrtStart = _sqrtPrice(id);
        uint256 l;
        if (v.quoteIs0) {
            l = ((sqrtStart > ref ? sqrtStart : ref) * SQRT_PRICE_DOWN_BPS) / BPS;
            if (l >= sqrtStart) revert BuybackNotReady();
        } else {
            l = ((sqrtStart < ref ? sqrtStart : ref) * SQRT_PRICE_UP_BPS) / BPS;
            if (l <= sqrtStart) revert BuybackNotReady();
        }
        if (l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
        if (l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(l);
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
