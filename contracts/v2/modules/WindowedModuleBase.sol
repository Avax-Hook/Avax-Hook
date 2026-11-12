// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title WindowedModuleBase
/// @notice HookModuleBase plus block windows. A windowed rule runs twice, like v1's anti-snipe: for its
///         first `window` blocks after the launch on the bonding curve (SwapContext.phase == PHASE_CURVE), and
///         again for its first `window` blocks after the pool opens (v1 counted pool windows from the
///         graduation block). The hook keeps `openBlock` in `poolInfo`, which is a wide read, so the module
///         caches it the first time it sees a pool swap or liquidity change (it never changes once open).
abstract contract WindowedModuleBase is HookModuleBase {
    /// @dev UNKNOWN until the first callback after the pool opened, then the open block. Seeded at
    ///      registration so caching it inside a gas-capped callback isn't a fresh storage write.
    mapping(PoolId => uint256) internal _openBlockCache;
    /// @dev Block of the launch (onRegister), where curve-phase windows start.
    mapping(PoolId => uint256) internal _launchBlock;
    uint256 internal constant UNKNOWN = type(uint256).max;

    constructor(address _hook) HookModuleBase(_hook) {}

    /// @dev Call from onRegister (at launch).
    function _seedWindows(PoolId id) internal {
        _openBlockCache[id] = UNKNOWN;
        _launchBlock[id] = block.number;
    }

    /// @dev Inside the window of the trade's phase: from launch on the curve, from the pool open in the pool.
    function _inWindow(SwapContext calldata ctx, uint256 window) internal returns (bool) {
        if (ctx.phase == ModuleCaps.PHASE_CURVE) return window != 0 && block.number < _launchBlock[ctx.poolId] + window;
        return _within(ctx.poolId, window);
    }

    /// @dev The current phase's window (view): the curve's until the pool opens, then the pool's.
    function _activeView(PoolId id, uint256 window) internal view returns (bool) {
        if (window == 0) return false;
        uint256 b = _openBlockView(id);
        if (b == 0) b = _launchBlock[id];
        return b != 0 && block.number < b + window;
    }

    /// @dev Block the pool opened in (0 while on the curve). Caches it once known.
    function _openBlock(PoolId id) internal returns (uint256 b) {
        b = _openBlockCache[id];
        if (b == UNKNOWN || b == 0) {
            b = AvaxHookV2(payable(hook)).poolInfo(id).openBlock;
            if (b != 0) _openBlockCache[id] = b;
        }
    }

    function _openBlockView(PoolId id) internal view returns (uint256 b) {
        b = _openBlockCache[id];
        if (b == UNKNOWN || b == 0) b = AvaxHookV2(payable(hook)).poolInfo(id).openBlock;
    }

    /// @dev True while `block.number` is inside the first `window` blocks after the pool opened.
    function _within(PoolId id, uint256 window) internal returns (bool) {
        if (window == 0) return false;
        uint256 b = _openBlock(id);
        return b != 0 && block.number < b + window;
    }

    function _withinView(PoolId id, uint256 window) internal view returns (bool) {
        if (window == 0) return false;
        uint256 b = _openBlockView(id);
        return b != 0 && block.number < b + window;
    }
}
