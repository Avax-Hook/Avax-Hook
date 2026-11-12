// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHookModule, ModuleCaps} from "../../interfaces/IHookModule.sol";

/// @title RouterOnlyGuard
/// @notice Closes the ERC-6909 claims bypass of transfer rules (2026-11-12). Transfer rules (max wallet,
///         vesting, lists, caps) only see holdings through the token's transfer callback. A contract that swaps
///         straight on the PoolManager can keep the bought tokens as PoolManager claims (`mint`) and later sell
///         them by burning claims (`burn`): the ERC-20 never moves, so no rule ever runs. While a rule is
///         active, its module calls `check` from onBeforeSwap and refuses every pool swap whose trader is
///         unknown (did not come through the trusted AvaxHook router, see IHookModule.SwapContext): the router
///         always delivers ERC-20 tokens to a wallet (and pulls them from it), so its trades pass the rule.
///         Bonding-curve trades are untouched (the trader is always known there).
///   Trade-off: aggregators and bots that call the PoolManager directly are refused while the rule is active.
library RouterOnlyGuard {
    error RouterOnly();

    /// @dev Reverts for a PHASE_POOL swap with no trusted trader. Buy-side rules call it for buys only: on
    ///      the sell path a module without BLOCKS_SELLS is isolated by the hook (its revert is ignored).
    function check(IHookModule.SwapContext calldata ctx) internal pure {
        if (ctx.phase == ModuleCaps.PHASE_POOL && ctx.trader == address(0)) revert RouterOnly();
    }

    /// @dev Buys only (receiver rules: the claims position is built by the buy).
    function checkBuy(IHookModule.SwapContext calldata ctx) internal pure {
        if (ctx.isBuy) check(ctx);
    }
}
