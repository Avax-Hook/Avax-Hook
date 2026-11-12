// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {PolarityModuleV2} from "../contracts/v2/modules/PolarityModuleV2.sol";

interface IHookRegistryView {
    function moduleRegistry() external view returns (address);
}

/// Deploys PolarityModuleV2 (redeem only after graduation) for the live v3 hook, with the same price
/// assets as the v3 PolarityModule (AVAX, USDC, USDt: Chainlink-backed quotes). The module has no owner.
/// The deployer only pays gas; registering is the Safe's (it owns the registry). The script prints the
/// Safe's two calls: registry.addModule(impl, metadata) and registry.setDeprecated(<old Polarity id>, true)
/// (the old module stays live for the pairs already launched on it; it just stops being offered).
///
///   forge script script/DeployPolarityModuleV2.s.sol --rpc-url avalanche --broadcast --verify
///   then, as for every module (full metadata from config/hook-modules/polarity.json):
///     V2_STATE=script/v3-state.json node script/hooks-v2-ops.mjs register Polarity <impl> hash
///     V2_STATE=script/v3-state.json node script/hooks-v2-ops.mjs deprecate <old id> true hash
///
/// Env: ADMIN_PRIVATE_KEY (deployer), HOOK (default: the v3 hook), OLD_POLARITY (default: the v3 one).
/// The v2 stack doesn't need it: HookTokenV2's curve transfer lock already keeps v1 redeem closed there.
contract DeployPolarityModuleV2 is Script {
    address constant V3_HOOK = 0xfD0753147E21C3F61e38aE27d6634B8C38CB6AcC;
    address constant V3_POLARITY = 0xF6639817F70f9cb38f16F0F6fe18BE5aB08b111B;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    string constant META = '{"id":"polarity","name":"Polarity","contract":"PolarityModuleV2"}';

    function run() external returns (PolarityModuleV2 m) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envOr("HOOK", V3_HOOK);
        address oldPol = vm.envOr("OLD_POLARITY", V3_POLARITY);
        HookModuleRegistry registry = HookModuleRegistry(IHookRegistryView(hook).moduleRegistry());
        require(registry.hook() == hook, "registry not bound to HOOK");
        uint32 oldId = registry.idOf(oldPol);
        require(oldId != 0, "OLD_POLARITY is not in this registry");

        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (address(0), USDC, USDT);
        vm.startBroadcast(pk);
        m = new PolarityModuleV2(hook, assets);
        vm.stopBroadcast();
        require(m.hook() == hook, "module bound to another hook");

        console2.log("PolarityModuleV2", address(m));
        console2.log("  hook    ", hook);
        console2.log("  registry", address(registry), "owner", registry.owner());
        console2.log("  replaces module id", oldId, oldPol);
        console2.log("Safe call 1 (registry.addModule, short metadata; hooks-v2-ops register stores the full JSON):");
        console2.log("  to", address(registry));
        console2.logBytes(abi.encodeCall(HookModuleRegistry.addModule, (address(m), META)));
        console2.log("Safe call 2 (registry.setDeprecated(old id, true)):");
        console2.log("  to", address(registry));
        console2.logBytes(abi.encodeCall(HookModuleRegistry.setDeprecated, (oldId, true)));
    }
}
