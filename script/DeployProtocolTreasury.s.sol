// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolTreasury} from "../contracts/ProtocolTreasury.sol";

/// Deploys ProtocolTreasury (holds protocol $HOOK / AVAX for MMs, listings, partnerships). Owner = the
/// Safe by default, so every withdrawal needs 2-of-3 signatures. Not a lock: owner withdraws any time.
///
///   forge script script/DeployProtocolTreasury.s.sol --rpc-url avalanche --broadcast --verify
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), OWNER override.
contract DeployProtocolTreasury is Script {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;

    function run() external returns (ProtocolTreasury t) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address owner = vm.envOr("OWNER", SAFE);
        vm.startBroadcast(pk);
        t = new ProtocolTreasury(owner);
        vm.stopBroadcast();
        console2.log("ProtocolTreasury", address(t));
        console2.log("  owner", owner);
    }
}
