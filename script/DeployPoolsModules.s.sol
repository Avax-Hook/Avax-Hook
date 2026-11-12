// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {RoyaltyModule, IBlueprintRoyalty} from "../contracts/v2/modules/RoyaltyModule.sol";

/// Phase-1 modules of the existing-token profile, bound to its hook (same bytecode as the launch hook's
/// modules, only the immutable hook differs; the two pots use their pools versions under
/// contracts/v2/pools/modules: rescue by pool id, 2% pot cap, orphaned pots to the protocol), plus the
/// profile's RoyaltyModule (profile 1). Run after
/// DeployPools; reads and extends its state file. The Safe then registers them in the pools registry and
/// approves the royalty module as a use recorder (node script/hooks-v2-ops.mjs pools <mode>).
///   forge script script/DeployPoolsModules.s.sol --rpc-url <rpc> --broadcast
/// Env: ADMIN_PRIVATE_KEY, POOLS_STATE (default script/pools-state.json), BLUEPRINT_REGISTRY (default: live),
///      REDEPLOY_MODULES=yes to deploy a fresh set although the state file already lists modules.
/// The state file is only written by a broadcasting run.
contract DeployPoolsModules is Script {
    address constant LIVE_BLUEPRINT_REGISTRY = 0x79114a00eA631b8F0fD83C2D6B060e883e7f8717;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        string memory file = vm.envOr("POOLS_STATE", string("script/pools-state.json"));
        string memory json = vm.readFile(file);
        address hook = vm.parseJsonAddress(json, ".AvaxHookV2");
        require(hook.code.length > 0, "no pools hook code");
        address blueprints = vm.envOr("BLUEPRINT_REGISTRY", LIVE_BLUEPRINT_REGISTRY);
        bool redeploy = keccak256(bytes(vm.envOr("REDEPLOY_MODULES", string("")))) == keccak256("yes");
        string[] memory keys = vm.parseJsonKeys(json, "$");
        for (uint256 i; i < keys.length; ++i) {
            require(
                redeploy || !vm.contains(keys[i], "module:"),
                "modules already deployed (see POOLS_STATE); set REDEPLOY_MODULES=yes for a new set"
            );
        }

        // Keep in sync with config/pools.ts POOL_MODULE_IDS (royalty is added below).
        string[11] memory names = [
            "AutoBurn",
            "DynamicFee",
            "VolatilityFee",
            "LpRewards",
            "NthBuyPot",
            "LastBuyerPot",
            "MevShield",
            "WhaleGuard",
            "SellTaxDecay",
            "MarketHours",
            "MarketHoursSellsOpen"
        ];
        // Artifact per name: "<Name>Module" unless listed here (pools-profile versions).
        string memory k = "pools";
        vm.serializeJson(k, json);
        vm.startBroadcast(pk);
        for (uint256 i; i < names.length; ++i) {
            string memory art = string.concat(names[i], "Module");
            if (_isPoolsPot(names[i])) art = string.concat(names[i], "PoolsModule");
            bytes memory init = abi.encodePacked(vm.getCode(string.concat(art, ".sol:", art)), abi.encode(hook));
            address m;
            assembly ("memory-safe") {
                m := create(0, add(init, 0x20), mload(init))
            }
            require(m != address(0) && m.code.length > 0, "module deploy failed");
            vm.serializeAddress(k, string.concat("module:", names[i]), m);
            console2.log("POOLS MODULE", names[i], m);
        }
        RoyaltyModule royalty = new RoyaltyModule(hook, IBlueprintRoyalty(blueprints), 1);
        vm.stopBroadcast();
        string memory out = vm.serializeAddress(k, "module:Royalty", address(royalty));
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            vm.writeJson(out, file);
        } else {
            console2.log("dry run: state file untouched");
        }
        console2.log("POOLS MODULE Royalty", address(royalty));
    }

    function _isPoolsPot(string memory name) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        return h == keccak256("NthBuyPot") || h == keccak256("LastBuyerPot");
    }
}
