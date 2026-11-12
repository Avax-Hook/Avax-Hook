// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title AutoBurnModule
/// @notice v1 "Auto burn": `burnBps` of every pool buy's token output is sent to 0x…dEaD. Supply only goes
///         down. Sells are never touched.
///         Both phases: bonding-curve buys burn the same share of their tokens.
contract AutoBurnModule is HookModuleBase {
    struct Config {
        uint16 burnBps; // 1 .. 500 (5%)
    }

    struct Burn {
        uint16 burnBps;
        uint128 totalBurned;
    }

    uint16 public constant MAX_BURN_BPS = 500;

    mapping(PoolId => Burn) internal _burns;

    event AutoBurn(PoolId indexed id, uint256 amount);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.burnBps == 0 || c.burnBps > MAX_BURN_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        Burn storage b = _burns[id];
        if (b.burnBps != 0) revert AlreadyRegistered();
        b.burnBps = abi.decode(config, (Config)).burnBps;
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return new Credit[](0);
        Burn storage b = _burns[ctx.poolId];
        uint256 amount = (ctx.amountOut * b.burnBps) / BPS;
        if (amount == 0) return new Credit[](0);
        b.totalBurned += uint128(amount);
        emit AutoBurn(ctx.poolId, amount);
        return _one(ModuleCaps.BURN, amount);
    }

    function burnOf(PoolId id) external view returns (Burn memory) {
        return _burns[id];
    }
}
