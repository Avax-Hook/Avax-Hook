// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AvaxHookZap} from "../contracts/v2/AvaxHookZap.sol";
import {AvaxHookLimitOrders} from "../contracts/v2/AvaxHookLimitOrders.sol";

/// Deploys AvaxHookLimitOrders on Avalanche. Owned by the zap's owner (the Safe) from the constructor,
/// so there is nothing to hand over; fees go to the launchpad's protocol recipient (the treasury).
///
///   forge script script/DeployLimitOrders.s.sol --rpc-url avalanche --broadcast
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), ZAP (default: the live AvaxHookZap),
///      FEE_BPS (default 10 = 0.1%, cap 100), KEEPER_FEE in wei (default 0.003 AVAX, cap 0.1),
///      FEE_RECIPIENT / OWNER overrides.
contract DeployLimitOrders is Script {
    address constant LIVE_ZAP = 0x9C608BAeE175F3faaB83D18a6a805379043e990d;

    function run() external returns (AvaxHookLimitOrders lo) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        AvaxHookZap zap = AvaxHookZap(payable(vm.envOr("ZAP", LIVE_ZAP)));
        require(address(zap).code.length != 0, "missing zap");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(10)));
        uint88 keeperFee = uint88(vm.envOr("KEEPER_FEE", uint256(0.003 ether)));
        address feeTo = vm.envOr("FEE_RECIPIENT", zap.launchpad().protocolRecipient());
        address owner = vm.envOr("OWNER", zap.owner());

        vm.startBroadcast(pk);
        lo = new AvaxHookLimitOrders(zap, feeBps, keeperFee, feeTo, owner);
        vm.stopBroadcast();

        console2.log("AvaxHookLimitOrders", address(lo));
        console2.log("  fee bps", feeBps, "to", feeTo);
        console2.log("  keeper fee (wei)", keeperFee);
        console2.log("  owner  ", owner);
    }
}
