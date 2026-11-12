// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {V1PortBase, SpoofSwapper} from "./V1PortBase.t.sol";

contract LastBuyerPotModuleTest is V1PortBase {
    HookTokenV2 t;
    PoolKey key;
    PoolId id;

    function setUp() public override {
        super.setUp();
        (t, key) = _one(timerPotId, _timerCfg(200, 600, 0.5 ether));
        id = _id(key);
    }

    // v1 test_timerPot
    // The graduation's curve buys already filled the pot and made the last curve buyer lead.
    function test_timerPot() public {
        uint256 pot0 = timerPot.potOf(id).pot;
        assertGt(pot0, 0);
        assertTrue(timerPot.potOf(id).leader != address(0));
        _routerBuy(alice, t, 5 ether);
        vm.warp(vm.getBlockTimestamp() + 100);
        _routerBuy(bob, t, 5 ether); // bob leads
        assertEq(timerPot.potOf(id).leader, bob);
        assertEq(timerPot.endsAt(id), block.timestamp + 600);
        vm.warp(vm.getBlockTimestamp() + 599);
        timerPot.settle(id);
        assertEq(hook.claimable(bob, NATIVE), 0); // not yet
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(carol); // anyone settles
        timerPot.settle(id);
        assertEq(hook.claimable(bob, NATIVE), pot0 + 0.2 ether);
        assertEq(timerPot.potOf(id).leader, address(0));
        assertEq(hook.claimable(address(timerPot), NATIVE), 0);
    }

    // A finished round is paid at the next qualifying buy, that buy's own share included, and a new
    // round starts with the new buyer leading.
    function test_nextQualifyingBuySettlesAndLeads() public {
        uint256 pot0 = timerPot.potOf(id).pot;
        _routerBuy(bob, t, 5 ether);
        vm.warp(vm.getBlockTimestamp() + 601);
        _routerBuy(carol, t, 0.4 ether); // below the minimum: funds the pot, doesn't settle or lead
        assertEq(timerPot.potOf(id).leader, bob);
        _routerBuy(carol, t, 1 ether);
        assertEq(hook.claimable(bob, NATIVE), pot0 + 0.1 ether + 0.008 ether + 0.02 ether);
        assertEq(timerPot.potOf(id).leader, carol);
        assertEq(timerPot.potOf(id).pot, 0);
        _routerBuy(alice, t, 1 ether); // carol's round still running: alice takes over the lead
        assertEq(timerPot.potOf(id).leader, alice);
        assertEq(timerPot.potOf(id).pot, 0.02 ether);
    }

    // I-1: a pot filled only by non-router buys has no leader; it goes to the creator after
    // TIMER_ORPHAN_SECONDS instead of sitting stuck.
    function test_I1_orphanPotGoesToCreator() public {
        vm.warp(vm.getBlockTimestamp() + 601);
        timerPot.settle(id); // the curve round ends: its leader is paid, nobody leads now
        assertEq(timerPot.potOf(id).leader, address(0));
        _directBuy(key, 10 ether);
        uint256 pot = timerPot.potOf(id).pot;
        assertEq(pot, 0.2 ether);
        uint256 c0 = hook.claimable(creator, NATIVE);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        timerPot.settle(id);
        assertEq(hook.claimable(creator, NATIVE), c0); // too early
        vm.warp(vm.getBlockTimestamp() + timerPot.TIMER_ORPHAN_SECONDS());
        timerPot.settle(id);
        assertEq(hook.claimable(creator, NATIVE) - c0, pot);
        assertEq(timerPot.potOf(id).pot, 0);
    }

    // HK-3: only the router names a buyer; a spoofer can't make someone else (or itself) lead.
    function test_HK3_spoofedBuyerCantLead() public {
        SpoofSwapper s = new SpoofSwapper(PM);
        vm.deal(address(s), 10 ether);
        address leader0 = timerPot.potOf(id).leader; // the last curve buyer
        s.buyAs(key, 1 ether, alice, address(0));
        assertEq(timerPot.potOf(id).leader, leader0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        timerPot.validateConfig(_timerCfg(0, 600, 1));
        vm.expectRevert();
        timerPot.validateConfig(_timerCfg(1_001, 600, 1));
        vm.expectRevert();
        timerPot.validateConfig(_timerCfg(100, 59, 1));
        vm.expectRevert();
        timerPot.validateConfig(_timerCfg(100, 7 days + 1, 1));
        vm.expectRevert();
        timerPot.validateConfig(_timerCfg(100, 600, 0));
        timerPot.validateConfig(_timerCfg(1_000, 7 days, 1));
    }
}
