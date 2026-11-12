// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AvaxHookV2} from "../../../contracts/v2/AvaxHookV2.sol";
import {HookLaunchpadV2} from "../../../contracts/v2/HookLaunchpadV2.sol";
import {BlueprintRegistryV1} from "../../../contracts/v2/blueprints/BlueprintRegistryV1.sol";
import {ExampleBlueprints} from "../../../script/PublishExampleBlueprints.s.sol";

/// The example blueprints publish and launch on the LIVE launchpad and modules (mainnet fork), so their ids
/// and configs are valid against what is deployed.
contract ExampleBlueprintsTest is Test {
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));
    address admin = makeAddr("admin");

    function test_examplesPublishAndLaunchLive() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        BlueprintRegistryV1 reg = new BlueprintRegistryV1(address(this));
        ExampleBlueprints.Example[3] memory ex = ExampleBlueprints.all();
        vm.deal(admin, 100 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(admin);
            uint32 id = reg.publish(ex[i].name, ExampleBlueprints.URI, 0, ex[i].spec, 0, 0);
            assertEq(reg.blueprint(id).author, admin);

            // launch exactly what the app prefills from the spec
            (uint32[] memory ids, bytes[] memory cfgs, uint16 creatorFee, uint24 baseFee) =
                abi.decode(reg.specOf(id), (uint32[], bytes[], uint16, uint24));
            HookLaunchpadV2.LaunchArgs memory a;
            a.name = ex[i].name;
            a.symbol = "EX";
            a.core = AvaxHookV2.CoreConfig({creatorFeeBps: creatorFee, baseFeePips: baseFee});
            a.moduleIds = ids;
            a.moduleConfigs = cfgs;
            uint256 fee = PAD.creationFee();
            vm.prank(admin);
            address token = PAD.launch{value: fee}(a);
            assertTrue(token != address(0));

            // and it trades on the curve
            address buyer = makeAddr(string(abi.encodePacked("buyer", i)));
            vm.deal(buyer, 10 ether);
            vm.roll(block.number + 1);
            vm.prank(buyer);
            PAD.buy{value: 1 ether}(token, 0);
        }
        assertEq(reg.count(), 3);
    }
}
