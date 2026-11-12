// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";
import {AvaxHookRouterV2} from "../contracts/v2/AvaxHookRouterV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {HookTokenV2} from "../contracts/v2/HookTokenV2.sol";
import {PartnerFeeModule} from "../contracts/v2/modules/PartnerFeeModule.sol";

/// Fork check of the Berry partner fee on the live v2 stack, the way it goes live: deploy PartnerFeeModule
/// (Safe-owned), the Safe batch from `hooks-v2-ops.mjs partner` (addModule + registerPartner), then a launch
/// shaped like Berry's (AVAX, no guard, creator fee = user fee − 0.3% − 0.2%) that trades on the curve,
/// graduates and trades in the pool; the treasury claims from the hook.
contract PartnerFeeFork is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    address constant BERRY_TREASURY = 0xb5b3a4A5F6FFbA1250EF6F044c364F71e84e526E;
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));
    AvaxHookV2 constant HOOK = AvaxHookV2(payable(0x179278C7ECD2cFbc003D76985Ba05f11DDc36ACc));
    AvaxHookRouterV2 constant ROUTER = AvaxHookRouterV2(payable(0xC8B2b67A1E286f74648A705617d54a0415fc651a));
    HookModuleRegistry constant REGISTRY = HookModuleRegistry(0xA84Eb2215c88e76048552471E1a486Ae68762286);
    Currency constant NATIVE = Currency.wrap(address(0));
    bytes32 constant BERRY = keccak256("berry");

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
    }

    function test_berryLaunch() public {
        PartnerFeeModule pf = new PartnerFeeModule(address(HOOK), SAFE);
        vm.startPrank(SAFE);
        uint32 id = REGISTRY.addModule(address(pf), '{"id":"partner-fee","hidden":true}');
        pf.registerPartner(BERRY, BERRY_TREASURY, 100);
        vm.stopPrank();

        address user = makeAddr("berryUser");
        vm.deal(user, 100_000 ether);
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Berry Test";
        a.symbol = "BTEST";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 0}); // 1% user fee
        a.moduleIds = new uint32[](1);
        a.moduleIds[0] = id;
        a.moduleConfigs = new bytes[](1);
        a.moduleConfigs[0] = abi.encode(BERRY, uint16(20));
        a.devBuy = 1 ether;
        vm.prank(user);
        address token = PAD.launch{value: PAD.creationFee() + 1 ether}(a);
        (bytes32 pid, uint16 bps) = pf.partnerOf(token);
        assertEq(pid, BERRY);
        assertEq(bps, 20);
        uint256 c0 = HOOK.claimable(BERRY_TREASURY, NATIVE);
        assertEq(c0, 0.002 ether, "dev buy paid 0.2%");

        address trader = makeAddr("trader");
        vm.deal(trader, 100_000 ether);
        vm.prank(trader);
        PAD.buy{value: 10 ether}(token, 0);
        assertEq(HOOK.claimable(BERRY_TREASURY, NATIVE) - c0, 0.02 ether, "curve buy");

        // fill the curve
        uint256 target = uint256(PAD.getLaunch(token).target);
        vm.prank(trader);
        PAD.buy{value: target * 2}(token, 0);
        assertTrue(PAD.getLaunch(token).graduated, "graduated");

        uint256 c1 = HOOK.claimable(BERRY_TREASURY, NATIVE);
        vm.prank(trader);
        uint256 got = ROUTER.buy{value: 10 ether}(token, 10 ether, 0, address(0), block.timestamp, "");
        assertEq(HOOK.claimable(BERRY_TREASURY, NATIVE) - c1, 0.02 ether, "pool buy");
        uint256 c2 = HOOK.claimable(BERRY_TREASURY, NATIVE);
        vm.startPrank(trader);
        HookTokenV2(token).approve(address(ROUTER), got);
        ROUTER.sell(token, got, 0, block.timestamp, "");
        vm.stopPrank();
        assertGt(HOOK.claimable(BERRY_TREASURY, NATIVE), c2, "pool sell");

        uint256 owed = HOOK.claimable(BERRY_TREASURY, NATIVE);
        uint256 b0 = BERRY_TREASURY.balance;
        vm.prank(BERRY_TREASURY);
        HOOK.claim(NATIVE, BERRY_TREASURY);
        assertEq(BERRY_TREASURY.balance - b0, owed);
        emit log_named_decimal_uint("Berry earned (AVAX)", owed, 18);
    }
}
