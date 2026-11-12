// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AvaxHookRouterV2} from "../contracts/v2/AvaxHookRouterV2.sol";
import {AvaxHookZap} from "../contracts/v2/AvaxHookZap.sol";

/// The v3 stack's AvaxHookZap (one-transaction aggregator buys and sells for pools whose modules are
/// identity-neutral), owned by the Safe. The neutral set is passed in at construction — the same modules
/// the live v2 Zap treats as neutral, by contract — so the Safe does not have to send 32 `setNeutral`
/// calls afterwards. `script/DeployV3Modules.s.sol` prints that list as `V3 NEUTRAL <addr>` lines.
///
///   NEUTRAL=0x…,0x… ROUTER_V3=0x… forge script script/DeployV3Zap.s.sol --rpc-url avalanche --broadcast
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), ROUTER_V3, NEUTRAL (comma-separated module
///      addresses), OWNER (the Safe).
///
/// Next: `ZAP=<this> forge script script/DeployLimitOrders.s.sol --rpc-url avalanche --broadcast`.
contract DeployV3Zap is Script {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;

    function run() external returns (AvaxHookZap zap) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        AvaxHookRouterV2 router = AvaxHookRouterV2(payable(vm.envAddress("ROUTER_V3")));
        require(address(router).code.length != 0, "no code at ROUTER_V3");
        address owner = vm.envOr("OWNER", SAFE);
        address[] memory neutral = vm.envOr("NEUTRAL", ",", new address[](0));
        for (uint256 i; i < neutral.length; ++i) {
            require(neutral[i].code.length != 0, "a NEUTRAL address has no code");
        }

        vm.startBroadcast(pk);
        zap = new AvaxHookZap(router, neutral, owner);
        vm.stopBroadcast();

        console2.log("V3 AvaxHookZap", address(zap));
        console2.log("  router    ", address(router));
        console2.log("  launchpad ", address(zap.launchpad()));
        console2.log("  neutral   ", neutral.length);
        console2.log("  owner     ", owner);
    }
}
