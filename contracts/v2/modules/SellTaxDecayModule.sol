// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";

/// @title SellTaxDecayModule
/// @notice v1 "Sell tax decay": sells pay an extra LP fee of `sellTaxPips` when the pool opens, falling in a
///         straight line to zero over `sellTaxBlocks` blocks. It is a fee, never a refusal, so it doesn't
///         declare BLOCKS_SELLS (if it ever failed, the sell would just skip the extra fee). Runs twice: on the
///         bonding curve it decays from the launch block and is an extra cut of the sell's quote added to the
///         graduation liquidity (the curve's LP-fee stand-in); in the pool it decays again from the open block.
contract SellTaxDecayModule is WindowedModuleBase {
    struct Config {
        uint32 sellTaxBlocks; // 1 .. 43,200 blocks
        uint24 sellTaxPips; // 1 .. 200,000 (20%) extra LP fee at open
    }

    uint32 public constant MAX_WINDOW_BLOCKS = 43_200;
    uint24 public constant MAX_SELL_TAX_PIPS = 200_000;

    mapping(PoolId => Config) internal _cfg;

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.sellTaxBlocks == 0 || c.sellTaxBlocks > MAX_WINDOW_BLOCKS) revert BadConfig();
        if (c.sellTaxPips == 0 || c.sellTaxPips > MAX_SELL_TAX_PIPS) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        if (_cfg[id].sellTaxBlocks != 0) revert AlreadyRegistered();
        _cfg[id] = abi.decode(config, (Config));
        _seedWindows(id);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24 fee, Credit[] memory) {
        if (!ctx.isBuy) {
            uint256 start = ctx.phase == ModuleCaps.PHASE_CURVE ? _launchBlock[ctx.poolId] : _openBlock(ctx.poolId);
            fee = uint24(_tax(_cfg[ctx.poolId], start));
        }
        return (fee, new Credit[](0));
    }

    /// @notice Current extra sell fee in pips.
    function currentSellTax(PoolId id) external view returns (uint256) {
        uint256 open = _openBlockView(id);
        return _tax(_cfg[id], open != 0 ? open : _launchBlock[id]);
    }

    function configOf(PoolId id) external view returns (Config memory) {
        return _cfg[id];
    }

    function _tax(Config memory c, uint256 openBlock) internal view returns (uint256) {
        if (openBlock == 0) return 0;
        uint256 elapsed = block.number - openBlock;
        if (elapsed >= c.sellTaxBlocks) return 0;
        return (uint256(c.sellTaxPips) * (c.sellTaxBlocks - elapsed)) / c.sellTaxBlocks;
    }
}
