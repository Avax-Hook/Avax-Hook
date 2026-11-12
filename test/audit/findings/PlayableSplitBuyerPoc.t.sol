// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {HookLaunchpadV2} from "../../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../../../contracts/v2/HookModuleRegistry.sol";
import {PartnerFeeModule} from "../../../contracts/v2/modules/PartnerFeeModule.sol";
import {PlayableSplitBuyer} from "../../../contracts/v2/PlayableSplitBuyer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Regression (was a finding): on the buy that completes the curve, HookLaunchpadV2._buy pulls only `paid`
/// (< amountIn) of an ERC-20 quote. PlayableSplitBuyer used to keep the excess forever; now it refunds
/// whatever the call leaves over to the caller, and the owner can rescue tokens sent to it by mistake.
contract PlayableSplitBuyerPoc is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    address constant HOUSE = 0x4E50EF6D688AEF8DF851A8F43d700b81113A8885;
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));
    HookModuleRegistry constant REGISTRY = HookModuleRegistry(0xA84Eb2215c88e76048552471E1a486Ae68762286);
    PartnerFeeModule constant PF = PartnerFeeModule(0xE1c6Dc3426035A7d51259303da9bbE76Aa836700);
    IERC20 constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    bytes32 constant GOATSINO = keccak256("goatsino");
    uint256 constant FLOOR = 50_000_000 ether;

    PlayableSplitBuyer buyer;

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        (address payout,,) = PF.partners(GOATSINO);
        if (payout == address(0)) {
            vm.prank(SAFE);
            PF.registerPartner(GOATSINO, HOUSE, 100);
        }
        buyer = new PlayableSplitBuyer(PAD, PF, USDC, GOATSINO, HOUSE, FLOOR, SAFE);
        vm.prank(SAFE);
        PAD.setTrustedCaller(address(buyer), true);
    }

    function test_excessOnCompletingBuyIsRefunded() public {
        address user = makeAddr("whale");
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Goat Playable";
        a.symbol = "GPLAY";
        a.quote = address(USDC);
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 100, baseFeePips: 0});
        a.moduleIds = new uint32[](1);
        a.moduleIds[0] = REGISTRY.idOf(address(PF));
        a.moduleConfigs = new bytes[](1);
        a.moduleConfigs[0] = abi.encode(GOATSINO, uint16(20));
        uint256 fee = PAD.creationFee();
        vm.deal(user, 10 ether);
        vm.prank(user);
        address token = PAD.launch{value: fee}(a);

        // Pay far more than the whole curve costs: the rest-buy completes the curve.
        uint256 total = 1_000_000e6;
        deal(address(USDC), user, total);
        vm.startPrank(user);
        USDC.approve(address(buyer), total);
        buyer.splitBuy{gas: 25_000_000}(token, total, 0);
        vm.stopPrank();

        uint256 back = USDC.balanceOf(user);
        console2.log("USDC refunded to the buyer (6dp):", back);
        assertTrue(PAD.getLaunch(token).complete, "curve completed");
        assertEq(USDC.balanceOf(address(buyer)), 0, "nothing left in the buyer");
        assertGt(back, 900_000e6, "user's excess came back");
        assertEq(USDC.allowance(address(buyer), address(PAD)), 0, "approval cleared");
    }

    function test_ownerCanRescueStrayTokens() public {
        address stranger = makeAddr("stranger");
        deal(address(USDC), address(buyer), 123e6);
        vm.expectRevert();
        vm.prank(stranger);
        buyer.rescue(address(USDC), stranger, 123e6);
        vm.prank(SAFE);
        buyer.rescue(address(USDC), SAFE, 123e6);
        assertEq(USDC.balanceOf(address(buyer)), 0);
    }
}
