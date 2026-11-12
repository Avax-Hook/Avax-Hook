// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title VolatilityFeeModule
/// @notice v1 "Volatility fee": the first swap in a block records the pool tick as the block's reference.
///         Every later swap in that block pays an extra LP fee of `volPipsPerTick` per tick the price has
///         already moved from it, up to `volMaxPips`. Sandwiches and pile-ons inside one block get expensive.
///         Applies to buys and sells; never refuses anything.
///         Pool phase only (pool ticks, LP fee): a no-op on the bonding curve.
contract VolatilityFeeModule is HookModuleBase {
    using StateLibrary for IPoolManager;

    struct Config {
        uint16 volPipsPerTick; // >= 1
        uint24 volMaxPips; // 1 .. 50,000 (5%)
    }

    struct Vol {
        Config cfg;
        uint64 block_;
        int24 startTick;
    }

    uint24 public constant MAX_VOL_FEE_PIPS = 50_000;

    mapping(PoolId => Vol) internal _vol;

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.volPipsPerTick == 0 || c.volMaxPips == 0 || c.volMaxPips > MAX_VOL_FEE_PIPS) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        Vol storage v = _vol[id];
        if (v.cfg.volPipsPerTick != 0) revert AlreadyRegistered();
        v.cfg = abi.decode(config, (Config));
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24 fee, Credit[] memory) {
        if (ctx.phase == ModuleCaps.PHASE_CURVE) return (0, new Credit[](0));
        Vol storage v = _vol[ctx.poolId];
        (, int24 tick,,) = poolManager.getSlot0(ctx.poolId);
        if (v.block_ != block.number) {
            v.block_ = uint64(block.number);
            v.startTick = tick;
        } else {
            fee = uint24(_fee(v.cfg, tick, v.startTick));
        }
        return (fee, new Credit[](0));
    }

    /// @notice Extra fee (pips) the next swap pays in the current block.
    function currentVolFee(PoolId id) external view returns (uint256) {
        Vol storage v = _vol[id];
        if (v.block_ != block.number) return 0;
        (, int24 tick,,) = poolManager.getSlot0(id);
        return _fee(v.cfg, tick, v.startTick);
    }

    function _fee(Config memory c, int24 tick, int24 startTick) internal pure returns (uint256) {
        int256 moved = int256(tick) - int256(startTick);
        uint256 extra = uint256(moved < 0 ? -moved : moved) * c.volPipsPerTick;
        return extra > c.volMaxPips ? c.volMaxPips : extra;
    }
}
