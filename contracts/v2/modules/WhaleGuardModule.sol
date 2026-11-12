// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";

/// @title WhaleGuardModule
/// @notice v1 "Whale guard": for `whaleBlocks` blocks after the pool opens, one transaction may buy at most
///         `maxBuyPerTx` quote units on the pool. The cap covers the whole transaction (`ctx.txVolume`, the
///         hook's transient per-tx buy volume), so splitting a buy into many swaps doesn't get around it
///         (HK-4). Sells are never touched. Runs twice: for `whaleBlocks` after the launch on the bonding curve,
///         and again after the pool opens.
contract WhaleGuardModule is WindowedModuleBase {
    struct Config {
        uint32 whaleBlocks; // 1 .. 43,200 blocks
        uint96 maxBuyPerTx; // quote units, > 0
    }

    uint32 public constant MAX_WINDOW_BLOCKS = 43_200;

    mapping(PoolId => Config) internal _cfg;

    error MaxBuyExceeded(uint256 attempted, uint256 cap);

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_BUY_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.whaleBlocks == 0 || c.whaleBlocks > MAX_WINDOW_BLOCKS || c.maxBuyPerTx == 0) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        if (_cfg[id].whaleBlocks != 0) revert AlreadyRegistered();
        _cfg[id] = abi.decode(config, (Config));
        _seedWindows(id);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy) {
            Config memory c = _cfg[ctx.poolId];
            if (ctx.txVolume > c.maxBuyPerTx && _inWindow(ctx, c.whaleBlocks)) {
                revert MaxBuyExceeded(ctx.txVolume, c.maxBuyPerTx);
            }
        }
        return (0, new Credit[](0));
    }

    function configOf(PoolId id) external view returns (Config memory) {
        return _cfg[id];
    }

    function active(PoolId id) external view returns (bool) {
        return _activeView(id, _cfg[id].whaleBlocks);
    }
}
