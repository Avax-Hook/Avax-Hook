// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AvaxHookZap} from "../contracts/v2/AvaxHookZap.sol";
import {AvaxHookLimitOrders} from "../contracts/v2/AvaxHookLimitOrders.sol";
import {AvaxHookLimitOrdersV2} from "../contracts/v2/AvaxHookLimitOrdersV2.sol";

/// Deploys AvaxHookLimitOrdersV2 (ERC-20 payouts a recipient can't take are credited, `withdrawToken`,
/// owner `sweep` of strays only). By default it copies the live v1 instance's zap and config (fee bps,
/// keeper fee, fee recipient, owner), so the site and keeper only change the address. Owned by the Safe from
/// the constructor: nothing to hand over.
///
///   v2 stack (replaces 0xBB32…80dc):
///     forge script script/DeployLimitOrdersV2.s.sol --rpc-url avalanche --broadcast --verify
///   v3 stack (replaces 0xa20b…398a):
///     OLD=0xa20bedcab867414b741a4331787d4b65817b398a forge script script/DeployLimitOrdersV2.s.sol \
///       --rpc-url avalanche --broadcast --verify
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), OLD (v1 instance to copy, default the v2-stack one),
///      ZAP / FEE_BPS / KEEPER_FEE (wei) / FEE_RECIPIENT / OWNER overrides.
/// Afterwards: the Safe pauses the old instance (`setConfig(fee, keeperFee, recipient, true)`; cancels still
/// work there), the keeper and site switch to the new address.
contract DeployLimitOrdersV2 is Script {
    address constant LIVE_V1 = 0xBB324987e484B1C03A41632fE6eE40D6544d80dc;

    function run() external returns (AvaxHookLimitOrdersV2 lo) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        AvaxHookLimitOrders old = AvaxHookLimitOrders(payable(vm.envOr("OLD", LIVE_V1)));
        require(address(old).code.length != 0, "missing OLD");
        AvaxHookZap zap = AvaxHookZap(payable(vm.envOr("ZAP", address(old.zap()))));
        require(address(zap).code.length != 0, "missing zap");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(old.feeBps())));
        uint88 keeperFee = uint88(vm.envOr("KEEPER_FEE", uint256(old.keeperFee())));
        address feeTo = vm.envOr("FEE_RECIPIENT", old.feeRecipient());
        address owner = vm.envOr("OWNER", old.owner());

        vm.startBroadcast(pk);
        lo = new AvaxHookLimitOrdersV2(zap, feeBps, keeperFee, feeTo, owner);
        vm.stopBroadcast();

        require(address(lo.router()) == address(old.router()) && address(lo.launchpad()) == address(old.launchpad()), "stack mismatch");
        console2.log("AvaxHookLimitOrdersV2", address(lo));
        console2.log("  replaces", address(old));
        console2.log("  zap     ", address(zap));
        console2.log("  fee bps", feeBps, "to", feeTo);
        console2.log("  keeper fee (wei)", keeperFee);
        console2.log("  owner   ", owner);
        console2.log("Safe, on the old instance (pause new fills; cancels keep working):");
        console2.log("  to", address(old));
        console2.logBytes(abi.encodeCall(AvaxHookLimitOrders.setConfig, (old.feeBps(), old.keeperFee(), old.feeRecipient(), true)));
    }
}
