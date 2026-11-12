// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BlueprintRegistryV1} from "../contracts/v2/blueprints/BlueprintRegistryV1.sol";
import {RoyaltyModule, IBlueprintRoyalty} from "../contracts/v2/modules/RoyaltyModule.sol";

/// Hook marketplace: BlueprintRegistryV1 plus one RoyaltyModule per hook profile, each approved as a use
/// recorder. Ownership of the registry is offered to OWNER (the Safe accepts; Ownable2Step).
///   forge script script/DeployBlueprints.s.sol --rpc-url <rpc> --broadcast
/// Env: ADMIN_PRIVATE_KEY, OWNER (required on mainnet), HOOK_V2 (the launch hook),
///      HOOK_POOLS (optional: the existing-token profile's hook).
/// Afterwards the Safe registers each RoyaltyModule in its profile's HookModuleRegistry
/// (`addModule(impl, config/hook-modules/royalty.json)`) and marks it zappable (identity-neutral).
contract DeployBlueprints is Script {
    uint256 constant AVALANCHE = 43114;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address owner = vm.envOr("OWNER", address(0));
        if (block.chainid == AVALANCHE) require(owner != address(0), "set OWNER (Safe) on mainnet");
        address hookV2 = vm.envAddress("HOOK_V2");
        address hookPools = vm.envOr("HOOK_POOLS", address(0));
        require(hookV2.code.length > 0, "no hook code at HOOK_V2");
        require(hookPools == address(0) || hookPools.code.length > 0, "no hook code at HOOK_POOLS");

        vm.startBroadcast(pk);
        BlueprintRegistryV1 registry = new BlueprintRegistryV1(vm.addr(pk));
        RoyaltyModule royV2 = new RoyaltyModule(hookV2, IBlueprintRoyalty(address(registry)), 0);
        registry.setRecorder(address(royV2), true);
        RoyaltyModule royPools;
        if (hookPools != address(0)) {
            royPools = new RoyaltyModule(hookPools, IBlueprintRoyalty(address(registry)), 1);
            registry.setRecorder(address(royPools), true);
        }
        if (owner != address(0)) registry.transferOwnership(owner);
        vm.stopBroadcast();

        console2.log("BlueprintRegistryV1", address(registry));
        console2.log("RoyaltyModule (launch hook)", address(royV2));
        if (hookPools != address(0)) console2.log("RoyaltyModule (pools hook)", address(royPools));
    }
}
