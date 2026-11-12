// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title LpRewardsModule
/// @notice v1 "LP rewards": `lpBps` of every pool buy's quote input is donated to in-range liquidity. Outside
///         LPs can only add full-range positions (core rule), so nobody can JIT a narrow range to skim it. The
///         launch position is locked for good, so its share deepens the creator's LP fees.
///         Pool phase only: a no-op on the bonding curve (there are no LPs yet).
contract LpRewardsModule is HookModuleBase {
    struct Config {
        uint16 lpBps; // 1 .. 1,000 (10%)
    }

    struct Rewards {
        uint16 lpBps;
        uint128 totalDonated;
    }

    uint16 public constant MAX_LP_BPS = 1_000;

    mapping(PoolId => Rewards) internal _rewards;

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.lpBps == 0 || c.lpBps > MAX_LP_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        Rewards storage r = _rewards[id];
        if (r.lpBps != 0) revert AlreadyRegistered();
        r.lpBps = abi.decode(config, (Config)).lpBps;
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy || ctx.phase == ModuleCaps.PHASE_CURVE) return (0, new Credit[](0));
        Rewards storage r = _rewards[ctx.poolId];
        uint256 amount = (ctx.amountIn * r.lpBps) / BPS;
        if (amount == 0) return (0, new Credit[](0));
        r.totalDonated += uint128(amount);
        return (0, _one(ModuleCaps.LP_DONATE, amount));
    }

    function rewardsOf(PoolId id) external view returns (Rewards memory) {
        return _rewards[id];
    }
}
