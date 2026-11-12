// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {LockEarnModule} from "../../contracts/v2/modules/LockEarnModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract LockEarnModuleTest is NewModulesBase {
    LockEarnModule le;
    uint32 leId;

    function setUp() public override {
        super.setUp();
        le = new LockEarnModule(address(hook));
        leId = modules.addModule(address(le), '{"name":"Lock & earn"}');
    }

    function _cfg(uint16 bps, uint32 minLock) internal pure returns (bytes memory) {
        return abi.encode(LockEarnModule.Config(bps, minLock));
    }

    function _lock(address who, HookTokenV2 t, uint256 amt, uint256 secs) internal {
        vm.prank(who);
        le.lock(address(t), amt, vm.getBlockTimestamp() + secs);
    }

    function _pending(HookTokenV2 t, address who) internal view returns (uint256 p) {
        (,, p) = le.lockOf(address(t), who);
    }

    function _locked(HookTokenV2 t) internal view returns (uint256 total) {
        (,, total,,,) = le.stats(address(t));
    }

    function test_configBoundsAndCaps() public {
        le.validateConfig(_cfg(1, 1 hours));
        le.validateConfig(_cfg(500, 180 days));
        vm.expectRevert();
        le.validateConfig(_cfg(0, 1 hours));
        vm.expectRevert();
        le.validateConfig(_cfg(501, 1 hours));
        vm.expectRevert();
        le.validateConfig(_cfg(100, 1 hours - 1));
        vm.expectRevert();
        le.validateConfig(_cfg(100, 180 days + 1));
        assertEq(
            le.capabilities(),
            ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS
        );
        assertEq(le.conflictGroups(), ModuleCaps.GROUP_SELL_LOCK);
    }

    /// Locked tokens can't be sold or sent (router, aggregator, plain transfer); the free part can.
    function test_lockBlocksMovesBelowLocked() public {
        (HookTokenV2 t, PoolKey memory key) = _launchOne(leId, _cfg(100, 1 hours));
        address h = _holder(0);
        uint256 bal = t.balanceOf(h);
        _lock(h, t, bal / 2, 7 days);
        (uint256 amt, uint256 unlockAt,) = le.lockOf(address(t), h);
        assertEq(amt, bal / 2);
        assertEq(unlockAt % 1 days, 0, "rounded to 00:00 UTC");
        assertGe(unlockAt, vm.getBlockTimestamp() + 7 days);
        uint256 free = bal - bal / 2;
        _sellReverts(h, t, free + 1);
        vm.prank(h);
        vm.expectRevert();
        t.transfer(carol, free + 1);
        vm.prank(h);
        t.approve(address(agg), bal);
        vm.expectRevert();
        agg.sellFrom(key, address(t), h, free + 1);
        // the free half moves
        _routerSell(h, t, free / 2);
        vm.prank(h);
        t.transfer(carol, free - free / 2);
        assertEq(t.balanceOf(h), bal / 2);
        // at the unlock time everything is free again
        vm.warp(unlockAt);
        _routerSell(h, t, bal / 2);
        assertEq(t.balanceOf(h), 0);
    }

    /// A lock on the curve binds curve sells too.
    function test_curveLock() public {
        HookTokenV2 t = _launch(_one(leId), _oneCfg(_cfg(100, 1 hours)), 0);
        vm.prank(alice);
        pad.buy{value: 5 ether}(address(t), 0);
        uint256 bal = t.balanceOf(alice);
        _lock(alice, t, bal, 2 days);
        vm.prank(alice);
        vm.expectRevert();
        pad.sell(address(t), 1, 0);
        // fees from curve trades go to the locker
        vm.prank(bob);
        pad.buy{value: 10 ether}(address(t), 0);
        le.poke(address(t));
        // alice's own buy fee waited in carry (no lockers yet) and joins with bob's
        assertApproxEqAbs(_pending(t, alice), 0.15 ether, 1e6);
    }

    /// Earnings are pro-rata to locked amounts and paid in AVAX by claim.
    function test_proRataAndClaim() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(200, 1 hours));
        le.poke(address(t)); // fold the graduation fees into carry (no lockers yet)
        address h0 = _holder(0);
        address h1 = _holder(1);
        uint256 x = t.balanceOf(h0) / 4;
        _lock(h0, t, x, 3 days);
        _lock(h1, t, 2 * x, 3 days);
        assertEq(_locked(t), 3 * x);
        _routerBuy(alice, t, 10 ether); // its fee folds the carry too
        _routerBuy(alice, t, 1 ether);
        le.poke(address(t));
        uint256 p0 = _pending(t, h0);
        uint256 p1 = _pending(t, h1);
        assertGt(p0, 0);
        assertApproxEqRel(p1, 2 * p0, 1e12, "twice the lock, twice the earnings");
        (,,, uint256 distributed,,) = le.stats(address(t));
        assertLe(p0 + p1, distributed, "never more than distributed");
        assertApproxEqRel(p0 + p1, distributed, 1e9, "all distributed is owed (index rounding only)");
        uint256 b0 = h1.balance;
        vm.prank(h1);
        uint256 got = le.claim(address(t));
        assertEq(got, p1);
        assertEq(h1.balance - b0, p1);
        assertEq(_pending(t, h1), 0);
        vm.prank(h1);
        vm.expectRevert(LockEarnModule.NothingOwed.selector);
        le.claim(address(t));
        assertEq(address(le).balance, le.cash(address(0)));
    }

    /// Fees with nobody locked carry forward to the first lockers.
    function test_carryForward() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(200, 1 hours));
        le.poke(address(t));
        (,,,,, uint256 carry) = le.stats(address(t));
        assertGt(carry, 0, "curve fees waiting");
        address h0 = _holder(0);
        _lock(h0, t, t.balanceOf(h0), 1 days);
        _routerBuy(alice, t, 1 ether);
        le.poke(address(t));
        assertApproxEqAbs(_pending(t, h0), carry + 0.02 ether, 1e9, "carry + the new fee");
    }

    /// Carry with no lockers for 180 days after the last unlock can be swept to the creator; not before.
    function test_sweepCarry() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(200, 1 hours));
        address h0 = _holder(0);
        _lock(h0, t, t.balanceOf(h0) / 2, 2 days);
        _routerBuy(alice, t, 1 ether); // earned while locked
        (, uint256 u,) = le.lockOf(address(t), h0);
        vm.warp(u + 1);
        _routerBuy(alice, t, 5 ether); // expires the lock; this fee finds no locker
        le.poke(address(t));
        (,,,,, uint256 carry) = le.stats(address(t));
        assertGt(carry, 0);
        vm.warp(u + 180 days - 1);
        vm.expectRevert(LockEarnModule.NothingOwed.selector);
        le.sweepCarry(address(t));
        vm.warp(u + 180 days);
        uint256 b0 = creator.balance;
        uint256 got = le.sweepCarry(address(t));
        assertEq(got, carry);
        assertEq(creator.balance - b0, carry);
        (,,,,, carry) = le.stats(address(t));
        assertEq(carry, 0);
        // the expired locker still claims what it earned
        vm.prank(h0);
        assertGt(le.claim(address(t)), 0);
    }

    /// Earning stops at the unlock time, even when nobody touches the lock.
    function test_earningStopsAtUnlock() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(200, 1 hours));
        address h0 = _holder(0);
        address h1 = _holder(1);
        _lock(h0, t, t.balanceOf(h0), 1 days);
        _lock(h1, t, t.balanceOf(h1), 30 days);
        _routerBuy(alice, t, 1 ether);
        (, uint256 u0,) = le.lockOf(address(t), h0);
        vm.warp(u0 + 1);
        _routerBuy(alice, t, 1 ether); // folds the previous fee, then expires h0's batch
        uint256 p0 = _pending(t, h0);
        uint256 p1 = _pending(t, h1);
        _routerBuy(alice, t, 5 ether);
        _routerBuy(alice, t, 5 ether);
        le.poke(address(t));
        assertEq(_pending(t, h0), p0, "expired lock earns nothing more");
        assertGt(_pending(t, h1), p1);
        assertEq(_locked(t), t.balanceOf(h1));
        (uint256 a0,,) = le.lockOf(address(t), h0);
        assertEq(a0, 0);
        vm.prank(h0);
        assertEq(le.claim(address(t)), p0);
    }

    function test_lockRules() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(100, 2 days));
        address h = _holder(0);
        uint256 bal = t.balanceOf(h);
        vm.startPrank(h);
        vm.expectRevert(LockEarnModule.BadLock.selector);
        le.lock(address(t), 1 ether, vm.getBlockTimestamp() + 2 days - 1); // below minLock
        vm.expectRevert(LockEarnModule.BadLock.selector);
        le.lock(address(t), 1 ether, vm.getBlockTimestamp() + 365 days + 1); // above a year
        vm.expectRevert(LockEarnModule.BadLock.selector);
        le.lock(address(t), bal + 1, vm.getBlockTimestamp() + 3 days); // more than held
        vm.expectRevert(LockEarnModule.BadLock.selector);
        le.lock(address(t), 0, vm.getBlockTimestamp() + 3 days); // nothing
        le.lock(address(t), bal / 2, vm.getBlockTimestamp() + 10 days);
        (, uint256 u,) = le.lockOf(address(t), h);
        vm.expectRevert(LockEarnModule.BadLock.selector);
        le.lock(address(t), 1, vm.getBlockTimestamp() + 3 days); // shorter than the active lock
        vm.expectRevert(LockEarnModule.BadLock.selector);
        le.lock(address(t), 0, u); // no change
        le.lock(address(t), 0, vm.getBlockTimestamp() + 20 days); // extend only
        le.lock(address(t), bal / 4, vm.getBlockTimestamp() + 20 days); // add
        (uint256 a, uint256 u2,) = le.lockOf(address(t), h);
        assertEq(a, bal / 2 + bal / 4);
        assertGt(u2, u);
        assertEq(_locked(t), a);
        vm.expectRevert(LockEarnModule.UnknownToken.selector);
        le.lock(address(0xBEEF), 1, vm.getBlockTimestamp() + 3 days);
        vm.stopPrank();
    }

    /// More unlock days than MAX_STEPS pass between trades: trades still work, poke catches up.
    function test_manyBatchesLag() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(100, 1 hours));
        for (uint256 i; i < 12; ++i) {
            address h = _holder(i);
            _lock(h, t, t.balanceOf(h) / 2, (i + 1) * 1 days);
        }
        vm.warp(vm.getBlockTimestamp() + 20 days);
        _routerBuy(alice, t, 1 ether);
        assertGt(_locked(t), 0, "only MAX_STEPS batches per trade");
        _routerSell(_holder(0), t, t.balanceOf(_holder(0))); // unlocked: sells fine
        le.poke(address(t));
        assertEq(_locked(t), 0);
    }

    function test_killSwitch() public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(200, 1 hours));
        address h = _holder(0);
        uint256 bal = t.balanceOf(h);
        _lock(h, t, bal, 5 days);
        _routerBuy(alice, t, 2 ether);
        le.poke(address(t));
        uint256 p = _pending(t, h);
        modules.disable(leId);
        le.rescue(address(t)); // nothing to move
        _routerSell(h, t, bal / 2); // no longer enforced
        vm.prank(h);
        assertEq(le.claim(address(t)), p);
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_owedNeverAboveDistributed(uint256 a, uint256 b, uint256 days0, uint256 buys) public {
        (HookTokenV2 t,) = _launchOne(leId, _cfg(300, 1 hours));
        address h0 = _holder(0);
        address h1 = _holder(1);
        _lock(h0, t, bound(a, 1e18, t.balanceOf(h0)), bound(days0, 1 days, 60 days));
        _lock(h1, t, bound(b, 1e18, t.balanceOf(h1)), bound(days0 >> 8, 1 days, 60 days));
        buys = bound(buys, 1, 6);
        for (uint256 i; i < buys; ++i) {
            vm.warp(vm.getBlockTimestamp() + 7 days);
            _routerBuy(alice, t, 3 ether);
        }
        le.poke(address(t));
        (,,, uint256 distributed,,) = le.stats(address(t));
        assertLe(_pending(t, h0) + _pending(t, h1), distributed);
        assertApproxEqAbs(le.accounted(address(0)), hook.claimable(address(le), NATIVE), 0);
    }
}
