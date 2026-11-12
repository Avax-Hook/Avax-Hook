// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuoteRegistry} from "../../contracts/QuoteRegistry.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookTokenV3} from "../../contracts/v3/HookTokenV3.sol";
import {PolarityModule} from "../../contracts/v2/modules/PolarityModule.sol";
import {PolarityModuleV2} from "../../contracts/v2/modules/PolarityModuleV2.sol";
import {V3Base} from "./V3Base.t.sol";

/// Polarity on the v3 stack (HookTokenV3: free transfers on the curve). v1 `redeem` relied on the v2 token's
/// curve transfer lock, so on v3 it pays out of the pot before graduation; PolarityModuleV2 checks
/// `hook.isOpen` itself and only opens redeem with the pool.
contract PolarityModuleV2V3Test is V3Base {
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    uint16 constant FEE = 100; // 1%

    PolarityModule pol1;
    PolarityModuleV2 pol2;
    uint32 pol1Id;
    uint32 pol2Id;

    function _registerModules() internal override {
        address[] memory a = new address[](3);
        (a[0], a[1], a[2]) = (address(0), USDC, USDT);
        pol1 = new PolarityModule(address(hook), a);
        pol2 = new PolarityModuleV2(address(hook), a);
        pol1Id = modules.addModule(address(pol1), '{"name":"Polarity"}');
        pol2Id = modules.addModule(address(pol2), '{"name":"Polarity v2"}');
        vm.mockCall(address(LIVE_QUOTES), abi.encodeWithSelector(QuoteRegistry.usdPrice.selector, address(0)), abi.encode(20e18));
    }

    function _cfg(uint8 side, address partner) internal pure returns (bytes memory) {
        return abi.encode(PolarityModuleV2.Config(address(0), side, 20, FEE, partner));
    }

    function _side(uint32 id, uint8 side, address partner) internal returns (HookTokenV3 t) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = id;
        cfgs[0] = _cfg(side, partner);
        t = _launch(ids, cfgs);
    }

    function _pair(uint32 id) internal returns (HookTokenV3 bull, HookTokenV3 bear) {
        bull = _side(id, 0, address(0));
        bear = _side(id, 1, address(bull));
    }

    /// The bug, on the live v1 code: a curve buyer redeems out of the BULL pot before graduation.
    function test_v1_redeemOpenOnTheCurve() public {
        (HookTokenV3 bull,) = _pair(pol1Id);
        uint256 got = _buy(alice, bull, 10 ether);
        assertFalse(pad.getLaunch(address(bull)).graduated);
        vm.startPrank(alice);
        bull.approve(address(pol1), type(uint256).max);
        uint256 paid = pol1.redeem(address(bull), got / 2, 0);
        vm.stopPrank();
        assertGt(paid, 0, "v1 pays out on the curve");
    }

    function test_redeemRevertsDuringCurve() public {
        (HookTokenV3 bull, HookTokenV3 bear) = _pair(pol2Id);
        uint256 got = _buy(alice, bull, 10 ether);
        _buy(bob, bear, 5 ether);
        (PolarityModuleV2.Pair memory p,,) = pol2.pairOf(address(bull));
        assertGt(p.potBull, 0, "curve fees fill the pot");

        vm.startPrank(alice);
        bull.approve(address(pol2), type(uint256).max);
        vm.expectRevert(PolarityModuleV2.NotGraduated.selector);
        pol2.redeem(address(bull), got / 2, 0);
        vm.stopPrank();

        // tokens move freely on v3 (a transfer to a fresh wallet works), the guard still holds
        vm.prank(alice);
        bull.transfer(carol, got / 4);
        vm.startPrank(carol);
        bull.approve(address(pol2), type(uint256).max);
        vm.expectRevert(PolarityModuleV2.NotGraduated.selector);
        pol2.redeem(address(bull), got / 4, 0);
        vm.stopPrank();
    }

    function test_redeemWorksAfterGraduation() public {
        (HookTokenV3 bull, HookTokenV3 bear) = _pair(pol2Id);
        uint256 got = _buy(alice, bull, 10 ether);
        _buy(bob, bear, 5 ether);
        _graduate(bull);
        assertTrue(hook.isOpen(pad.poolId(address(bull))));

        // BEAR is still on the curve: its redeem stays closed while BULL's opens
        vm.startPrank(bob);
        bear.approve(address(pol2), type(uint256).max);
        vm.expectRevert(PolarityModuleV2.NotGraduated.selector);
        pol2.redeem(address(bear), 1 ether, 0);
        vm.stopPrank();

        uint256 amount = got / 2;
        uint256 preview = pol2.previewRedeem(address(bull), amount);
        assertGt(preview, 0);
        uint256 bal = alice.balance;
        uint256 dead = bull.balanceOf(DEAD);
        vm.startPrank(alice);
        bull.approve(address(pol2), type(uint256).max);
        uint256 paid = pol2.redeem(address(bull), amount, preview);
        vm.stopPrank();
        assertEq(paid, preview);
        assertEq(alice.balance - bal, paid, "paid in AVAX");
        assertEq(bull.balanceOf(DEAD) - dead, amount, "burned to dEaD");
    }
}
