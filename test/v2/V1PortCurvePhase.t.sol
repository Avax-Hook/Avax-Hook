// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

/// Bonding-curve phase (SwapContext.phase == PHASE_CURVE) of the ported modules: window rules run from
/// the launch, pots / referral / burn work as in the pool, pool-only mechanics do nothing.
contract V1PortCurvePhaseTest is V1PortBase {
    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 got) {
        uint256 b0 = t.balanceOf(who);
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
        got = t.balanceOf(who) - b0;
    }

    function _curveSell(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        uint256 b0 = who.balance;
        vm.startPrank(who);
        t.approve(address(pad), amt);
        pad.sell(address(t), amt, 0);
        vm.stopPrank();
        out = who.balance - b0;
    }

    function _poolId(HookTokenV2 t) internal view returns (PoolId) {
        return _id(pad.poolKey(address(t)));
    }

    function test_whaleGuardFromLaunchOnTheCurve() public {
        HookTokenV2 t = _launch(_ids1(whaleId), _cfgs1(_whaleCfg(50, 2 ether)), 100);
        assertTrue(whale.active(_poolId(t)));
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 3 ether}(address(t), 0);
        _curveBuy(alice, t, 2 ether);
        vm.roll(vm.getBlockNumber() + 50);
        assertFalse(whale.active(_poolId(t)));
        _curveBuy(bob, t, 10 ether); // the curve window is over (and the pool gets its own window later)
    }

    function test_dumpGuardOnCurveSells() public {
        HookTokenV2 t = _launch(_ids1(dumpId), _cfgs1(_dumpCfg(50, 10)), 100);
        uint256 got = _curveBuy(alice, t, 20 ether);
        assertGt(got, 2_000_000 ether);
        vm.startPrank(alice);
        t.approve(address(pad), type(uint256).max);
        vm.expectRevert();
        pad.sell(address(t), 1_500_000 ether, 0);
        pad.sell(address(t), 1_000_000 ether, 0);
        vm.stopPrank();
    }

    function test_mevShieldOnTheCurve() public {
        HookTokenV2 t = _launch(_ids1(mevId), _cfgs1(_mevCfg(50, 5 gwei)), 100);
        vm.fee(25 gwei);
        vm.txGasPrice(31 gwei);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);
        vm.txGasPrice(26 gwei);
        _curveBuy(alice, t, 1 ether);
    }

    function test_sellTaxDecaysFromLaunchOnTheCurve() public {
        HookTokenV2 t = _launch(_ids1(sellTaxId), _cfgs1(_sellTaxCfg(100, 100_000)), 100);
        HookTokenV2 p = _launch(new uint32[](0), new bytes[](0), 100);
        PoolId id = _poolId(t);
        assertEq(sellTax.currentSellTax(id), 100_000);
        uint256 got = _curveBuy(alice, t, 10 ether);
        assertEq(_curveBuy(alice, p, 10 ether), got); // buys pay nothing extra
        uint256 taxed = _curveSell(alice, t, got / 2);
        uint256 plain = _curveSell(alice, p, got / 2);
        assertLt(taxed, plain); // ~10% of the gross quote kept for the graduation liquidity
        assertApproxEqRel(plain - taxed, (plain * 1_000) / 9_870, 0.02e18);
        vm.roll(vm.getBlockNumber() + 50);
        assertEq(sellTax.currentSellTax(id), 50_000);
    }

    function test_poolOnlyModulesDoNothingOnTheCurve() public {
        uint32[] memory ids = new uint32[](5);
        bytes[] memory cfgs = new bytes[](5);
        (ids[0], cfgs[0]) = (antiSnipeId, _antiSnipeCfg(150, 1 ether, 2_000));
        (ids[1], cfgs[1]) = (lpId, _lpCfg(500));
        (ids[2], cfgs[2]) = (buybackId, _buybackCfg(500, 1 ether));
        (ids[3], cfgs[3]) = (surgeId, _surgeCfg(100_000, 10));
        (ids[4], cfgs[4]) = (volId, _volCfg(1_000, 50_000));
        HookTokenV2 t = _launch(ids, cfgs, 100);
        HookTokenV2 p = _launch(new uint32[](0), new bytes[](0), 100);
        PoolId id = _poolId(t);
        // no cap, no tax, no LP-fee override, no donation: the same as a plain curve
        uint256 got = _curveBuy(alice, t, 5 ether);
        assertEq(got, _curveBuy(alice, p, 5 ether));
        assertEq(_curveBuy(alice, t, 5 ether), _curveBuy(alice, p, 5 ether));
        assertEq(_curveSell(alice, t, got), _curveSell(alice, p, got));
        assertEq(lpRewards.rewardsOf(id).totalDonated, 0);
        assertEq(buyback.vaultOf(id).saved, 0);
        assertEq(buyback.buybackReference(id), 0);
        assertEq(hook.claimable(hook.PROTOCOL(), NATIVE), 0); // core protocol fee stays in the launchpad on the curve
    }

    function test_potsCountCurveBuys() public {
        uint32[] memory ids = _ids2(nthPotId, timerPotId);
        HookTokenV2 t = _launch(ids, _cfgs2(_nthCfg(100, 2, 0.1 ether), _timerCfg(100, 600, 0.1 ether)), 100);
        PoolId id = _poolId(t);
        _curveBuy(alice, t, 1 ether);
        assertEq(nthPot.potOf(id).buyCount, 1);
        assertEq(nthPot.potOf(id).pot, 0.01 ether);
        assertEq(timerPot.potOf(id).leader, alice);
        assertEq(timerPot.potOf(id).pot, 0.01 ether);
        vm.roll(vm.getBlockNumber() + 1);
        _curveBuy(bob, t, 1 ether); // the 2nd counted buy wins the Nth pot
        assertEq(hook.claimable(bob, NATIVE), 0.02 ether);
        assertEq(timerPot.potOf(id).leader, bob);
        vm.warp(vm.getBlockTimestamp() + 601);
        timerPot.settle(id);
        assertEq(hook.claimable(bob, NATIVE), 0.02 ether + 0.02 ether);
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
    }

    function test_referralOnTheCurve() public {
        HookTokenV2 t = _launch(_ids1(referralId), _cfgs1(_referralCfg(100, 50)), 0);
        vm.prank(bob);
        pad.buyWithData{value: 10 ether}(address(t), 10 ether, 0, alice, "");
        assertEq(referral.referrerOf(bob), alice);
        assertEq(hook.claimable(alice, NATIVE), 0.05 ether);
        assertEq(hook.claimable(creator, NATIVE), 0.05 ether);
        vm.prank(carol);
        pad.buyWithData{value: 1 ether}(address(t), 1 ether, 0, carol, ""); // self-referral: nothing
        assertEq(referral.referrerOf(carol), address(0));
    }

    function test_autoBurnOnTheCurve() public {
        HookTokenV2 t = _launch(_ids1(burnId), _cfgs1(_burnCfg(200)), 100);
        HookTokenV2 p = _launch(new uint32[](0), new bytes[](0), 100);
        uint256 got = _curveBuy(alice, t, 5 ether);
        uint256 plain = _curveBuy(alice, p, 5 ether);
        assertEq(t.balanceOf(DEAD), plain - got);
        assertEq(t.balanceOf(DEAD), (plain * 200) / 10_000);
    }
}
