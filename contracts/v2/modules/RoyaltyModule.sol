// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

interface IBlueprintRoyalty {
    function royaltyOf(uint32 id) external view returns (address author, uint16 royaltyBps, uint8 profile, bool launchable);
    function recorder(address module) external view returns (bool);
    function recordUse(uint32 id, bytes32 poolId, address token) external;
}

/// @title RoyaltyModule
/// @notice Pays a marketplace blueprint's author: `bps` of every trade's quote amount (from the input on buys,
///         from the output on sells, like the creator fee and Tithe), as a claimable balance in AvaxHookV2
///         that the author withdraws with `claim(quote, to)`.
///   - The config names the blueprint; author and share must match BlueprintRegistryV1 exactly, the
///     blueprint must be launchable (not hidden) and made for this module's profile (0 = token launches,
///     1 = pools for existing tokens), so nobody can credit a blueprint with a different payee or share.
///     Each registration counts one use in the registry (this module must be an approved recorder).
///   - Every trade pays: bonding-curve buys and sells and every pool swap (router or not). Identity-neutral.
///   - Fixed forever after launch, like every module config.
contract RoyaltyModule is HookModuleBase {
    struct Config {
        uint32 blueprintId;
        address author;
        uint16 bps; // 0.01% .. 0.5%
    }

    IBlueprintRoyalty public immutable blueprints;
    /// @notice The blueprint profile this module's hook serves (module ids are not portable between profiles).
    uint8 public immutable profile;

    mapping(PoolId => Config) internal _cfg;

    error NotLaunchable();
    error WrongProfile();
    error NotRecorder();

    constructor(address _hook, IBlueprintRoyalty _blueprints, uint8 _profile) HookModuleBase(_hook) {
        blueprints = _blueprints;
        profile = _profile;
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public view override {
        Config memory c = abi.decode(config, (Config));
        (address author, uint16 bps, uint8 p, bool launchable) = blueprints.royaltyOf(c.blueprintId);
        if (!launchable) revert NotLaunchable();
        if (p != profile) revert WrongProfile();
        if (!blueprints.recorder(address(this))) revert NotRecorder();
        if (c.bps == 0 || c.author != author || c.bps != bps) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        if (_cfg[id].bps != 0) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        _cfg[id] = c;
        blueprints.recordUse(c.blueprintId, PoolId.unwrap(id), token);
    }

    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _royalty(_cfg[ctx.poolId], ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external view override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _royalty(_cfg[ctx.poolId], ctx.amountOut);
    }

    function configOf(PoolId id) external view returns (Config memory) {
        return _cfg[id];
    }

    function _royalty(Config memory c, uint256 amount) internal pure returns (Credit[] memory) {
        uint256 r = (amount * c.bps) / BPS;
        if (r == 0) return new Credit[](0);
        return _one(c.author, r);
    }
}
