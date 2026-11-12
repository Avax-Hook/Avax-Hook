// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {HookModuleBase, IAvaxHookV2View, IQuotePrices} from "./HookModuleBase.sol";

/// @title ReceiverRuleBase
/// @notice Shared plumbing for transfer rules that refuse RECEIVERS (holder-gated, allowlist, plague, alliances).
///   Tokens leaving the PoolManager are BUYS by default and checked, whichever pool they come from (this
///   token's hooked pool, a hookless or other-hook v4 pool of the same token) and whenever they are taken
///   (before or after the swap in an unlock). The one exception is liquidity of THIS pool:
///   - The module declares LIQUIDITY. When someone removes liquidity from this pool (or collects its fees,
///     liquidityDelta 0), `onLiquidity` adds the token amount that removal pays (the full-range principal at
///     the current price, rounded up, plus the position's owed token fees) to a per-pool allowance in
///     transient storage. PoolManager -> receiver moves that fail the rule consume that allowance instead of
///     reverting, so a non-qualifying LP can always withdraw its own liquidity and fees.
///   - No allowance is granted for a removal in a transaction that also ADDED liquidity to this pool, so a swap
///     output can't be parked as liquidity and pulled out unchecked in the same transaction. The rule holds in
///     either order: an add AFTER a removal wipes the allowance left, and reverts if some of it was already
///     used (remove, take the tokens out, re-add funded by a buy would otherwise move a buy past the rule).
///   - Accepted limits: the allowance isn't bound to a receiver (an LP can withdraw to any address, like a
///     transfer the rule would otherwise refuse); liquidity added in one transaction (e.g. funded from a buy
///     in that same unlock) and removed in a LATER one pays out unchecked; token claims paid from the hook's
///     ERC-6909 balance (`claim` -> PoolManager take) are checked like buys, so a non-qualifying claimant
///     claims to a qualifying address; LPs of hookless pools of this token who fail the rule must withdraw to
///     a qualifying address.
///   - Moves FROM the hook or FROM a module of this pool (payouts) are never treated as buys.
///   - Receivers that are modules of the same pool (Auto-LP vaults, pots) are exempt, like the hook itself.
///   - Foreign tokens a rule reads balances of must be AvaxHook v2 tokens (immutable, honest `balanceOf`) or
///     quote assets the live QuoteRegistry allows, so a creator can't point a rule at a token whose
///     `balanceOf` it controls and brick receives later.
abstract contract ReceiverRuleBase is HookModuleBase {
    using StateLibrary for IPoolManager;

    /// @dev Transient slot bases (per pool).
    bytes32 private constant ALLOWANCE = keccak256("avaxhook.receiver-rule.lp-allowance");
    bytes32 private constant ADDED = keccak256("avaxhook.receiver-rule.lp-added");
    bytes32 private constant USED = keccak256("avaxhook.receiver-rule.lp-used");

    /// @dev Whether the launched token is currency0 of its pool (set at registration).
    mapping(PoolId => bool) internal _tokenIs0;

    error BadForeignToken();
    error AddAfterLpAllowanceUsed();

    constructor(address _hook) HookModuleBase(_hook) {}

    /// @dev Call from onRegister.
    function _registerPool(PoolId id, address token, address quote) internal {
        _tokenIs0[id] = token < quote;
    }

    /// @notice Grants the LP-withdrawal allowance (removals / fee collects on this pool). Never reverts on adds
    ///         (adds are not isolated); removals are isolated by the hook, and the math here can't revert for
    ///         a full-range position (the only kind outside LPs can hold).
    ///         Known limit (final audit D-2): the allowance belongs to the transaction, not to the LP. In a bundle
    ///         (multicall, relayer, 4337) an LP who withdraws to a qualifying address leaves it unused and a later
    ///         buy in the same transaction can spend it (at most what the LPs withdrew); an add earlier in the
    ///         bundle withholds it, so a bundled honest removal to a non-qualifying address can fail (retry alone);
    ///         likewise an add to this pool later in a bundle whose earlier removal used the allowance reverts.
    function onLiquidity(PoolId id, address sender, bool isAdd, ModifyLiquidityParams calldata params)
        external
        virtual
        override
        onlyHook
    {
        if (isAdd) {
            // An add after a removal in the same transaction: the removal's allowance must not outlive it
            // (remove + re-add is net zero, and a buy taken out against that allowance would pass unchecked).
            if (_rtload(_slot(USED, id)) != 0) revert AddAfterLpAllowanceUsed();
            _rtstore(_slot(ADDED, id), 1);
            _rtstore(_slot(ALLOWANCE, id), 0);
            return;
        }
        if (_rtload(_slot(ADDED, id)) != 0) return;
        uint256 amount = _removalTokens(id, sender, params);
        bytes32 s = _slot(ALLOWANCE, id);
        uint256 cur = _rtload(s);
        unchecked {
            uint256 next = cur + amount;
            _rtstore(s, next < cur ? type(uint256).max : next);
        }
    }

    /// @dev Token amount a removal of `params` by `sender` pays out of this pool: principal + owed token fees.
    function _removalTokens(PoolId id, address sender, ModifyLiquidityParams calldata params)
        internal
        view
        returns (uint256 amount)
    {
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        uint160 lo = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(params.tickUpper);
        bool tokenIs0 = _tokenIs0[id];
        if (params.liquidityDelta < 0) {
            uint128 liq = uint128(uint256(-params.liquidityDelta));
            if (sqrtP < lo) sqrtP = lo;
            if (sqrtP > hi) sqrtP = hi;
            amount = tokenIs0
                ? SqrtPriceMath.getAmount0Delta(sqrtP, hi, liq, true)
                : SqrtPriceMath.getAmount1Delta(lo, sqrtP, liq, true);
        }
        (uint128 posLiq, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(id, sender, params.tickLower, params.tickUpper, params.salt);
        if (posLiq != 0) {
            (uint256 g0, uint256 g1) = poolManager.getFeeGrowthInside(id, params.tickLower, params.tickUpper);
            uint256 grown;
            unchecked {
                grown = tokenIs0 ? g0 - last0 : g1 - last1;
            }
            amount += FullMath.mulDiv(grown, posLiq, FixedPoint128.Q128);
        }
    }

    /// @dev Uses `amount` of this transaction's LP-withdrawal allowance if it covers it.
    function _useAllowance(PoolId id, uint256 amount) internal returns (bool) {
        bytes32 s = _slot(ALLOWANCE, id);
        uint256 cur = _rtload(s);
        if (cur < amount) return false;
        unchecked {
            _rtstore(s, cur - amount);
        }
        if (amount != 0) _rtstore(_slot(USED, id), 1);
        return true;
    }

    function _plumbing(address a) internal view returns (bool) {
        return a == address(poolManager) || a == hook || a == ModuleCaps.BURN || a == address(this)
            || a == IAvaxHookV2View(hook).launchpad();
    }

    /// @dev A module of this pool (only contracts are looked up).
    function _isPoolModule(PoolId id, address a) internal view returns (bool) {
        if (a.code.length == 0) return false;
        address[] memory mods = AvaxHookV2(payable(hook)).poolInfo(id).modules;
        for (uint256 i; i < mods.length; ++i) {
            if (mods[i] == a) return true;
        }
        return false;
    }

    /// @dev Last check before a rule refuses `from` -> `to` (`amount`): payouts from the hook pass, receivers that are
    ///      modules of this pool pass, and PoolManager outflows covered by this transaction's LP-withdrawal allowance
    ///      pass (consuming it). Payouts FROM a pool module are checked like any receive: a module that hands the
    ///      token to an address someone picks (Buyer rewards funded with the token itself) must not launder it past
    ///      the rule (final audit D-1). The receiver exemption is checked before the allowance so a module's own
    ///      claim doesn't use up an LP's allowance.
    function _excused(PoolId id, address from, address to, uint256 amount) internal returns (bool) {
        if (from == hook) return true;
        if (_isPoolModule(id, to)) return true;
        return from == address(poolManager) && _useAllowance(id, amount);
    }

    /// @dev Reverts unless `t` is an AvaxHook v2 token or an allowed quote asset (with code).
    function _checkForeignToken(address t, address self) internal view {
        if (t == self || t.code.length == 0 || !_v2OrQuote(t)) revert BadForeignToken();
    }

    function _v2OrQuote(address t) internal view returns (bool) {
        if (_v2Creator(t) != address(0)) return true;
        (bool allowed,,) = IQuotePrices(IAvaxHookV2View(hook).quoteRegistry()).quotes(t);
        return allowed;
    }

    /// @dev Creator of an AvaxHook v2 token as the hook records it, address(0) if `t` isn't one.
    function _v2Creator(address t) internal view returns (address) {
        if (t == address(0)) return address(0);
        AvaxHookV2 h = AvaxHookV2(payable(hook));
        AvaxHookV2.PoolView memory v = h.poolInfo(h.poolOfToken(t));
        return v.token == t ? v.creator : address(0);
    }

    /// @notice This transaction's remaining LP-withdrawal allowance for `id` (tokens). 0 outside a transaction.
    function lpAllowance(PoolId id) external view returns (uint256) {
        return _rtload(_slot(ALLOWANCE, id));
    }

    function _slot(bytes32 base, PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encode(base, id));
    }

    function _rtload(bytes32 s) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(s)
        }
    }

    function _rtstore(bytes32 s, uint256 v) private {
        assembly ("memory-safe") {
            tstore(s, v)
        }
    }
}
