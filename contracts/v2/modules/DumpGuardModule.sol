// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";

/// @title DumpGuardModule
/// @notice v1 "Dump guard": for `dumpBlocks` blocks after the pool opens, one transaction may sell at most
///         `maxSellBps` of the 1B supply into the pool. The cap covers the whole transaction (`ctx.txVolume`,
///         HK-4). Refusing sells is the rule, so the module declares BLOCKS_SELLS (otherwise the hook would
///         ignore its revert on the sell path). Runs twice: for `dumpBlocks` after the launch on the bonding
///         curve (curve sells), and again after the pool opens.
contract DumpGuardModule is WindowedModuleBase {
    struct Config {
        uint32 dumpBlocks; // 1 .. 43,200 blocks
        uint16 maxSellBps; // of the 1B supply, 1 .. 1,000 (0.01% .. 10%)
    }

    uint32 public constant MAX_WINDOW_BLOCKS = 43_200;
    uint16 public constant MAX_SELL_BPS = 1_000;

    mapping(PoolId => Config) internal _cfg;

    error MaxSellExceeded(uint256 attempted, uint256 cap);

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SELL_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.dumpBlocks == 0 || c.dumpBlocks > MAX_WINDOW_BLOCKS || c.maxSellBps == 0 || c.maxSellBps > MAX_SELL_BPS) {
            revert BadConfig();
        }
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        if (_cfg[id].dumpBlocks != 0) revert AlreadyRegistered();
        _cfg[id] = abi.decode(config, (Config));
        _seedWindows(id);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) {
            Config memory c = _cfg[ctx.poolId];
            uint256 cap = (TOTAL_SUPPLY * c.maxSellBps) / BPS;
            if (ctx.txVolume > cap && _inWindow(ctx, c.dumpBlocks)) revert MaxSellExceeded(ctx.txVolume, cap);
        }
        return (0, new Credit[](0));
    }

    function configOf(PoolId id) external view returns (Config memory) {
        return _cfg[id];
    }

    function maxSell(PoolId id) external view returns (uint256 cap, bool active) {
        Config memory c = _cfg[id];
        return ((TOTAL_SUPPLY * c.maxSellBps) / BPS, _activeView(id, c.dumpBlocks));
    }
}
