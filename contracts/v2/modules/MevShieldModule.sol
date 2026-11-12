// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";

/// @title MevShieldModule
/// @notice v1 "MEV shield": for `mevBlocks` blocks after the pool opens, a swap (buy or sell) whose
///         transaction pays more than `maxPriorityFee` wei per gas above the base fee reverts. Bounds kept from
///         v1 (L-3): the cap is at least 5 gwei, so ordinary tipped or legacy-gasPrice transactions pass, and
///         the window lasts at most 1,800 blocks. It refuses sells too, so it declares BLOCKS_SELLS. Runs twice:
///         for `mevBlocks` after the launch on the bonding curve, and again after the pool opens.
contract MevShieldModule is WindowedModuleBase {
    struct Config {
        uint32 mevBlocks; // 1 .. 1,800 blocks
        uint64 maxPriorityFee; // wei per gas above basefee, >= 5 gwei
    }

    uint64 public constant MIN_PRIORITY_CAP = 5 gwei;
    uint32 public constant MAX_MEV_BLOCKS = 1_800;

    mapping(PoolId => Config) internal _cfg;

    error PriorityFeeTooHigh(uint256 paid, uint256 cap);

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.mevBlocks == 0 || c.mevBlocks > MAX_MEV_BLOCKS || c.maxPriorityFee < MIN_PRIORITY_CAP) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        if (_cfg[id].mevBlocks != 0) revert AlreadyRegistered();
        _cfg[id] = abi.decode(config, (Config));
        _seedWindows(id);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        Config memory c = _cfg[ctx.poolId];
        uint256 priority = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0;
        if (priority > c.maxPriorityFee && _inWindow(ctx, c.mevBlocks)) {
            revert PriorityFeeTooHigh(priority, c.maxPriorityFee);
        }
        return (0, new Credit[](0));
    }

    function configOf(PoolId id) external view returns (Config memory) {
        return _cfg[id];
    }

    function active(PoolId id) external view returns (bool) {
        return _activeView(id, _cfg[id].mevBlocks);
    }
}
