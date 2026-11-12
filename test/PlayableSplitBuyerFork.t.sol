// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {HookTokenV2} from "../contracts/v2/HookTokenV2.sol";
import {PartnerFeeModule} from "../contracts/v2/modules/PartnerFeeModule.sol";
import {PlayableSplitBuyer} from "../contracts/v2/PlayableSplitBuyer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Fork check of a GOATsino "playable" launch on the live v2 stack: a USDC-quoted launch carrying the live
/// PartnerFeeModule with GOATsino's id (registered on mainnet on 2026-10-20), then one transaction that buys
/// the house its 50M floor and the launcher everything they paid beyond it. The only thing the Safe has to
/// do for this to work is `setTrustedCaller(buyer, true)`, which the test does the same way.
contract PlayableSplitBuyerFork is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    address constant HOUSE = 0x4E50EF6D688AEF8DF851A8F43d700b81113A8885; // GOATsino's own wallet
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));
    AvaxHookV2 constant HOOK = AvaxHookV2(payable(0x179278C7ECD2cFbc003D76985Ba05f11DDc36ACc));
    HookModuleRegistry constant REGISTRY = HookModuleRegistry(0xA84Eb2215c88e76048552471E1a486Ae68762286);
    PartnerFeeModule constant PF = PartnerFeeModule(0xE1c6Dc3426035A7d51259303da9bbE76Aa836700);
    IERC20 constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    bytes32 constant GOATSINO = keccak256("goatsino");
    uint256 constant FLOOR = 50_000_000 ether;

    PlayableSplitBuyer buyer;
    uint32 partnerModuleId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        partnerModuleId = REGISTRY.idOf(address(PF));
        // GOATsino is registered on mainnet; a fork from before that block registers it the way the Safe did.
        (address payout,,) = PF.partners(GOATSINO);
        if (payout == address(0)) {
            vm.prank(SAFE);
            PF.registerPartner(GOATSINO, HOUSE, 100);
        }
        buyer = new PlayableSplitBuyer(PAD, PF, USDC, GOATSINO, HOUSE, FLOOR, SAFE);
        vm.prank(SAFE);
        PAD.setTrustedCaller(address(buyer), true);
    }

    /// A GOATsino launch, quoted in USDC, with nothing bought in the launch itself.
    function _launch(address who, bool partnered) internal returns (address token) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = partnered ? "Goat Playable" : "Plain Token";
        a.symbol = partnered ? "GPLAY" : "PLAIN";
        a.quote = address(USDC);
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 100, baseFeePips: 0});
        if (partnered) {
            a.moduleIds = new uint32[](1);
            a.moduleIds[0] = partnerModuleId;
            a.moduleConfigs = new bytes[](1);
            a.moduleConfigs[0] = abi.encode(GOATSINO, uint16(20));
        }
        uint256 fee = PAD.creationFee(); // read before the prank: the inner call would consume it
        vm.deal(who, 10 ether);
        vm.prank(who);
        token = PAD.launch{value: fee}(a);
    }

    function test_splitBuy_houseGetsTheFloor_launcherTheRest() public {
        address user = makeAddr("goatLauncher");
        address token = _launch(user, true);

        uint256 floorCost = buyer.quoteFloor(token);
        emit log_named_decimal_uint("floor costs (USDC)", floorCost, 6);
        assertGt(floorCost, 0, "floor priced");

        // The launcher pays for the floor and for 20M of its own on top.
        uint256 total = floorCost * 2;
        deal(address(USDC), user, total);
        vm.startPrank(user);
        USDC.approve(address(buyer), total);
        (uint256 spent, uint256 houseGot, uint256 restGot) = buyer.splitBuy(token, total, 0);
        vm.stopPrank();

        emit log_named_decimal_uint("house got", houseGot, 18);
        emit log_named_decimal_uint("launcher got", restGot, 18);
        assertEq(spent, floorCost, "floor spent as quoted");
        assertGe(houseGot, FLOOR, "the house is never short");
        assertLe(houseGot, FLOOR + (FLOOR * 100) / 10_000, "and never far over");
        assertEq(IERC20(token).balanceOf(HOUSE), houseGot, "the floor is in the house's own wallet");
        assertEq(IERC20(token).balanceOf(user), restGot, "the rest is the launcher's");
        assertGt(restGot, 0, "the launcher kept what it paid beyond the floor");
        assertEq(USDC.balanceOf(address(buyer)), 0, "no quote left in the buyer");
        assertEq(USDC.balanceOf(user), 0, "every cent went into the curve");
        assertEq(IERC20(token).balanceOf(address(buyer)), 0, "the buyer holds no token");
        // The curve is live and the floor is the only thing sold besides the launcher's part.
        HookLaunchpadV2.Launch memory l = PAD.getLaunch(token);
        assertEq(uint256(l.tokensSold), houseGot + restGot, "nothing else was sold");
        assertEq(l.creator, user, "the launcher is the creator");
    }

    /// Exactly the floor: the house gets it all and nothing is bought for the launcher.
    function test_splitBuy_exactFloor() public {
        address user = makeAddr("exact");
        address token = _launch(user, true);
        uint256 floorCost = buyer.quoteFloor(token);
        deal(address(USDC), user, floorCost);
        vm.startPrank(user);
        USDC.approve(address(buyer), floorCost);
        (, uint256 houseGot, uint256 restGot) = buyer.splitBuy(token, floorCost, 0);
        vm.stopPrank();
        assertGe(houseGot, FLOOR);
        assertEq(restGot, 0, "nothing left to buy");
        assertEq(IERC20(token).balanceOf(user), 0);
    }

    function test_splitBuy_refusesBelowTheFloor() public {
        address user = makeAddr("tooLittle");
        address token = _launch(user, true);
        uint256 floorCost = buyer.quoteFloor(token);
        deal(address(USDC), user, floorCost);
        vm.startPrank(user);
        USDC.approve(address(buyer), floorCost);
        vm.expectRevert(abi.encodeWithSelector(PlayableSplitBuyer.BelowFloor.selector, floorCost));
        buyer.splitBuy(token, floorCost - 1, 0);
        vm.stopPrank();
    }

    /// A launch that isn't GOATsino's is none of this contract's business.
    function test_splitBuy_refusesAnotherLaunch() public {
        address user = makeAddr("plain");
        address token = _launch(user, false);
        deal(address(USDC), user, 1_000e6);
        vm.startPrank(user);
        USDC.approve(address(buyer), 1_000e6);
        vm.expectRevert(PlayableSplitBuyer.NotPartnerLaunch.selector);
        buyer.splitBuy(token, 1_000e6, 0);
        vm.stopPrank();
    }

    /// The floor is bought at the opening price: a buy landing first only makes it cost more, never less.
    function test_quoteFloor_followsTheCurve() public {
        address user = makeAddr("curve");
        address token = _launch(user, true);
        uint256 atOpen = buyer.quoteFloor(token);

        address sniper = makeAddr("sniper");
        deal(address(USDC), sniper, 2_000e6);
        vm.startPrank(sniper);
        USDC.approve(address(PAD), 2_000e6);
        PAD.buyWithQuote(token, 2_000e6, 0);
        vm.stopPrank();

        uint256 after_ = buyer.quoteFloor(token);
        emit log_named_decimal_uint("floor at open (USDC)", atOpen, 6);
        emit log_named_decimal_uint("floor after a 2,000 USDC buy", after_, 6);
        assertGt(after_, atOpen, "the floor costs more once someone else has bought");

        // It still delivers the floor, just dearer: the launcher pays the live price.
        deal(address(USDC), user, after_);
        vm.startPrank(user);
        USDC.approve(address(buyer), after_);
        (, uint256 houseGot,) = buyer.splitBuy(token, after_, 0);
        vm.stopPrank();
        assertGe(houseGot, FLOOR);
    }

    /// The house holds real tokens from the launch, and the curve phase keeps them where they are.
    function test_houseCannotMoveBeforeGraduation() public {
        address user = makeAddr("locked");
        address token = _launch(user, true);
        uint256 floorCost = buyer.quoteFloor(token);
        deal(address(USDC), user, floorCost);
        vm.startPrank(user);
        USDC.approve(address(buyer), floorCost);
        buyer.splitBuy(token, floorCost, 0);
        vm.stopPrank();

        vm.prank(HOUSE);
        vm.expectRevert(HookTokenV2.CurvePhaseTransfer.selector);
        IERC20(token).transfer(makeAddr("goatHouseContract"), 1 ether);
    }
}
