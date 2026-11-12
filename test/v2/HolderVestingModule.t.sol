// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HolderVestingModule} from "../../contracts/v2/modules/HolderVestingModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// Isolated: each top-level call is its own transaction (buys of one transaction count together).
/// forge-config: default.isolate = true
contract HolderVestingModuleTest is NewModulesBase {
    HolderVestingModule hv;
    uint32 hvId;
    HookTokenV2 t;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        hv = new HolderVestingModule(address(hook));
        hvId = modules.addModule(address(hv), '{"name":"Holder vesting"}');
        // every buy of 0.1%+ vests: 1 day cliff, then 25% a day (all free after 5 days)
        (t, key) = _launchOne(hvId, _cfg(0, 10, 1 days, 2_500, 1 days));
    }

    function _cfg(uint32 window, uint16 minBuy, uint32 cliff, uint16 step, uint32 period) internal pure returns (bytes memory) {
        return abi.encode(HolderVestingModule.Config(window, minBuy, cliff, step, period));
    }

    function _locked(HookTokenV2 tok, address w) internal view returns (uint256 l) {
        (l,,,) = hv.vestingOf(address(tok), w);
    }

    function test_capabilities() public view {
        assertEq(hv.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS);
        assertEq(hv.conflictGroups(), ModuleCaps.GROUP_SELL_LOCK);
        assertTrue(t.transferRules());
    }

    function test_curveBuysVestThenUnlockInSteps() public {
        address h = _holder(5);
        uint256 bal = t.balanceOf(h);
        (uint256 locked, uint256 base, uint256 start, uint256 unlockAt) = hv.vestingOf(address(t), h);
        assertEq(locked, bal);
        assertEq(base, bal);
        assertEq(unlockAt, start + 5 days);
        bytes memory err = _sellError(h, t, 1 ether);
        assertTrue(_has(err, HolderVestingModule.StillLocked.selector));
        vm.prank(h);
        vm.expectRevert(abi.encodeWithSelector(HolderVestingModule.StillLocked.selector, h, bal - 1, bal));
        t.transfer(bob, 1);
        vm.warp(start + 1 days); // the cliff: nothing yet
        assertEq(hv.transferable(address(t), h), 0);
        vm.warp(start + 2 days); // 25%
        uint256 free = hv.transferable(address(t), h);
        assertEq(free, bal - (bal * 7_500) / 10_000);
        _sellReverts(h, t, free + 1);
        _routerSell(h, t, free / 2);
        // tokens received wallet-to-wallet are free
        vm.prank(h);
        t.transfer(bob, free / 2);
        _routerSell(bob, t, free / 2);
        assertEq(_locked(t, bob), 0);
        vm.warp(start + 5 days); // all free
        assertEq(_locked(t, h), 0);
        _routerSell(h, t, t.balanceOf(h));
    }

    function test_smallBuysDontVest() public {
        uint256 a = _routerBuy(alice, t, 1 ether); // ~0.02% < 0.1%
        assertLt(a, 1_000_000 ether);
        assertEq(_locked(t, alice), 0);
        _routerSell(alice, t, a);
    }

    function test_splitBuysInOneTxVestTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 100 ether);
        m.buyTwice{value: 8 ether}(address(t), 4 ether, 4 ether); // ~0.07% each, ~0.14% together
        uint256 bal = t.balanceOf(address(m));
        assertGt(bal, 1_000_000 ether);
        assertEq(_locked(t, address(m)), bal);
    }

    /// A second vesting buy joins the existing schedule: exactly L + A locked, the start never moves.
    function test_mergeKeepsSchedule() public {
        uint256 a = _routerBuy(alice, t, 20 ether);
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(_locked(t, alice), a);
        vm.warp(t0 + 3 days); // 50% unlocked
        uint256 l = _locked(t, alice);
        assertEq(l, a / 2);
        uint256 b = _routerBuy(alice, t, 20 ether);
        uint256 now_ = vm.getBlockTimestamp();
        (uint256 locked,, uint256 start, uint256 unlockAt) = hv.vestingOf(address(t), alice);
        assertEq(locked, l + b);
        assertEq(start, t0);
        assertEq(unlockAt, t0 + 5 days);
        assertGt(now_, t0);
        assertEq(hv.transferable(address(t), alice), a - l); // the unlocked half stays free
        _routerSell(alice, t, a - l);
    }

    function test_earlyWindowOnly() public {
        (HookTokenV2 t2,) = _launchOne(hvId, _cfg(1 hours, 10, 1 days, 2_500, 1 days));
        assertTrue(hv.vestingOpen(address(t2)));
        assertGt(_locked(t2, _holder(5)), 0); // curve buyers bought inside the window
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertFalse(hv.vestingOpen(address(t2)));
        uint256 a = _routerBuy(alice, t2, 20 ether);
        assertEq(_locked(t2, alice), 0);
        _routerSell(alice, t2, a);
    }

    /// An aggregator that takes the bought tokens itself holds them locked and can't pass them on.
    /// Claims bypass guard (2026-11-12): buys vest forever here, so a direct PoolManager buy is refused with
    /// RouterOnly. A contract that buys through the router and holds the tokens is still locked as the buyer.
    function test_aggregatorBuyLocksTheAggregator() public {
        _aggSwapRouterOnly(key, true, -int256(20 ether));
        MultiSwapper ms = new MultiSwapper(router);
        ms.buyTwice{value: 20 ether}(address(t), 10 ether, 10 ether);
        uint256 bal = t.balanceOf(address(ms));
        assertGt(bal, 0);
        assertEq(_locked(t, address(ms)), bal);
        vm.prank(address(ms));
        vm.expectRevert();
        t.transfer(carol, bal);
    }

    function test_curvePhase() public {
        HookTokenV2 t2 = _launch(_one(hvId), _oneCfg(_cfg(0, 10, 1 days, 2_500, 1 days)), 0);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t2), 0);
        uint256 bal = t2.balanceOf(alice);
        assertEq(_locked(t2, alice), bal);
        vm.prank(alice);
        try pad.sell(address(t2), bal / 10, 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, HolderVestingModule.StillLocked.selector));
        }
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(alice);
        pad.sell(address(t2), bal, 0);
    }

    function test_creatorNotExempt() public {
        uint256 c = _routerBuy(creator, t, 20 ether);
        assertEq(_locked(t, creator), c);
        _sellReverts(creator, t, 1 ether);
    }

    function test_configBounds() public {
        vm.expectRevert();
        hv.validateConfig(_cfg(365 days + 1, 10, 1 days, 2_500, 1 days));
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 1_001, 1 days, 2_500, 1 days));
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 10, 1 days, 0, 1 days));
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 10, 1 days, 10_001, 1 days));
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 10, 1 days, 2_500, 59));
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 10, 1 days, 2_500, 30 days + 1));
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 10, 365 days, 10_000, 60)); // the safety valve: over 365 days in all
        vm.expectRevert();
        hv.validateConfig(_cfg(0, 10, 0, 100, 4 days)); // 100 steps x 4 days
        hv.validateConfig(_cfg(0, 0, 0, 10_000, 60));
        hv.validateConfig(_cfg(365 days, 1_000, 335 days, 10_000, 30 days));
        hv.validateConfig(_cfg(0, 10, 5 days, 1_000, 30 days)); // 5 + 300 days
    }

    function test_onlyHook() public {
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        hv.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }

    /// Old schedule (cliff 1 day, 25% a day) evaluated by hand.
    function _oldLocked(uint256 base, uint256 start, uint256 at) internal pure returns (uint256) {
        uint256 e = at - start;
        uint256 f = e < 1 days ? 0 : ((e - 1 days) / 1 days) * 2_500;
        if (f > 10_000) f = 10_000;
        return (base * (10_000 - f)) / 10_000;
    }

    /// L-1: merges lock exactly L + A, never delay any already scheduled token (locked'(t) <= locked(t) + A, up
    /// to 2 wei of rounding, at every later time), never extend the schedule, and end within 365 days.
    function testFuzz_mergeAndSchedule(uint96 a, uint96 b, uint32 gap, uint32 later) public {
        uint256 x = bound(a, 1_000_000 ether, 50_000_000 ether);
        uint256 y = bound(b, 1_000_000 ether, 50_000_000 ether);
        gap = uint32(bound(gap, 0, 10 days));
        later = uint32(bound(later, 0, 10 days));
        address w = makeAddr("fuzzWallet");
        deal(address(t), w, x); // L-1: a wallet never vests more than it holds
        vm.prank(address(hook));
        hv.onTransfer(_id(key), address(t), address(router), address(PM), w, x);
        assertEq(_locked(t, w), x);
        (, uint256 base0, uint256 start0, uint256 unlock0) = hv.vestingOf(address(t), w);
        vm.warp(vm.getBlockTimestamp() + gap);
        uint256 l = _locked(t, w);
        deal(address(t), w, x + y);
        vm.prank(address(hook));
        hv.onTransfer(_id(key), address(t), address(router), address(PM), w, y);
        (uint256 locked, uint256 base, uint256 start, uint256 unlockAt) = hv.vestingOf(address(t), w);
        assertEq(locked, l + y);
        assertLe(locked, base);
        assertLe(unlockAt, vm.getBlockTimestamp() + 365 days);
        if (l > 0) {
            assertEq(start, start0); // the schedule never moves
            assertEq(unlockAt, unlock0);
        }
        uint256 now_ = vm.getBlockTimestamp();
        for (uint256 dt; dt <= 6 days; dt += 12 hours) {
            uint256 at = now_ + dt;
            vm.warp(at);
            uint256 old = l > 0 ? _oldLocked(base0, start0, at) : 0;
            assertLe(_locked(t, w), old + y + 2, "an earlier token unlocks later");
        }
        vm.warp(now_ + later);
        assertLe(_locked(t, w), locked);
        vm.warp(unlockAt);
        assertEq(_locked(t, w), 0);
        assertLe(start, vm.getBlockTimestamp());
    }

    /// L-1: a buy never locks more than the wallet holds (it sent tokens away earlier in the transaction).
    function test_vestsAtMostTheBalance() public {
        address w = makeAddr("sender");
        deal(address(t), w, 3_000_000 ether); // received 5M, already passed 2M on
        vm.prank(address(hook));
        hv.onTransfer(_id(key), address(t), address(router), address(PM), w, 5_000_000 ether);
        assertEq(_locked(t, w), 3_000_000 ether);
        deal(address(t), w, 0); // nothing left: nothing vests
        address w2 = makeAddr("empty");
        vm.prank(address(hook));
        hv.onTransfer(_id(key), address(t), address(router), address(PM), w2, 5_000_000 ether);
        (,, uint256 start,) = hv.vestingOf(address(t), w2);
        assertEq(start, 0);
    }
}
