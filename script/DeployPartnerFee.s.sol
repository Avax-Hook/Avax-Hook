// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PartnerFeeModule} from "../contracts/v2/modules/PartnerFeeModule.sol";

/// Deploys PartnerFeeModule for the live AvaxHookV2, owned by the Safe from the constructor (it registers
/// partners). Then `hooks-v2-ops.mjs partner <impl> <mode>`: registry.addModule + Zap setNeutral + Berry.
///
///   forge script script/DeployPartnerFee.s.sol --rpc-url avalanche --broadcast
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), HOOK / OWNER overrides.
contract DeployPartnerFee is Script {
    address constant LIVE_HOOK = 0x179278C7ECD2cFbc003D76985Ba05f11DDc36ACc;
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;

    function run() external returns (PartnerFeeModule m) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envOr("HOOK", LIVE_HOOK);
        address owner = vm.envOr("OWNER", SAFE);
        vm.startBroadcast(pk);
        m = new PartnerFeeModule(hook, owner);
        vm.stopBroadcast();
        console2.log("PartnerFeeModule", address(m));
        console2.log("  hook ", hook);
        console2.log("  owner", owner);
    }
}
