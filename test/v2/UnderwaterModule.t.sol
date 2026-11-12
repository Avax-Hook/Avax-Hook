// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {UnderwaterModule} from "../../contracts/v2/modules/UnderwaterModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract UnderwaterModuleTest is NewModulesBase {
    UnderwaterModule uw;
    uint32 uwId;
    uint32 constant IVL = 5 minutes;
    uint16 constant SHARE = 2_500;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        uw = new UnderwaterModule(address(hook), SAFE);
        uwId = modules.addModule(address(uw), '{"name":"Underwater"}');
        vm.prank(SAFE);
        uw.setKeeper(keeper);
    }

    function _cfg(uint16 bps, uint16 hold, uint32 ivl, uint16 roundBps) internal pure returns (bytes memory) {
        return abi.encode(UnderwaterModule.Config(bps, hold, ivl, roundBps, SHARE));
    }

    function _cfg5(uint16 bps, uint16 hold, uint32 ivl, uint16 roundBps, uint16 share) internal pure returns (bytes memory) {
        return abi.encode(UnderwaterModule.Config(bps, hold, ivl, roundBps, share));
    }

    function _dist(HookTokenV2 t, address[] memory l) internal returns (uint256 paid, uint256 n) {
        vm.prank(keeper);
        (paid, n) = uw.distribute(address(t), l);
    }

    /// The most one round may pay `w` (its per-round and lifetime caps).
    function _maxPay(HookTokenV2 t, address w) internal view returns (uint256 m) {
        (,,, m,) = uw.position(address(t), w);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = a < b ? (a, b) : (b, a);
    }

    function _basis(HookTokenV2 t, address w) internal view returns (uint256 basis) {
        (basis,,,,) = uw.position(address(t), w);
    }

    function _gap(HookTokenV2 t, address w) internal view returns (uint256 gap) {
        (,, gap,,) = uw.position(address(t), w);
    }

    function _pot(HookTokenV2 t) internal view returns (uint256 pot) {
        (pot,,,,) = uw.stats(address(t));
    }

    /// Graduated pool where alice bought high and curve holders dumped after her.
    function _underwaterPool(uint16 roundBps, uint256 dumpers) internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(_one(uwId), _oneCfg(_cfg(300, 0, IVL, roundBps)), 0);
        key = _graduateN(t, 40, 0);
        vm.warp(vm.getBlockTimestamp() + IVL); // the pool price has a history
        _routerBuy(alice, t, 50 ether);
        for (uint256 i; i < dumpers; ++i) {
            address h = _holder(i);
            _routerSell(h, t, t.balanceOf(h));
        }
        vm.warp(vm.getBlockTimestamp() + IVL);
        vm.roll(vm.getBlockNumber() + 1);
        uw.reconcile();
    }

    function test_configBoundsAndCaps() public {
        uw.validateConfig(_cfg5(1, 0, 5 minutes, 500, 1));
        uw.validateConfig(_cfg5(500, 100, 30 days, 10_000, 5_000));
        vm.expectRevert();
        uw.validateConfig(_cfg(0, 0, IVL, 500));
        vm.expectRevert();
        uw.validateConfig(_cfg(501, 0, IVL, 500));
        vm.expectRevert();
        uw.validateConfig(_cfg(100, 101, IVL, 500));
        vm.expectRevert();
        uw.validateConfig(_cfg(100, 0, 5 minutes - 1, 500));
        vm.expectRevert();
        uw.validateConfig(_cfg(100, 0, 30 days + 1, 500));
        vm.expectRevert();
        uw.validateConfig(_cfg(100, 0, IVL, 499));
        vm.expectRevert();
        uw.validateConfig(_cfg(100, 0, IVL, 10_001));
        vm.expectRevert();
        uw.validateConfig(_cfg5(100, 0, IVL, 500, 0));
        vm.expectRevert();
        uw.validateConfig(_cfg5(100, 0, IVL, 500, 5_001));
        assertEq(uw.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER);
        assertEq(uw.conflictGroups(), 0);
        assertEq(uw.owner(), SAFE);
        assertEq(uw.keeper(), keeper);
    }

    /// Only the keeper (or the Safe) runs rounds; only the Safe sets the keeper.
    function test_keeperOnly() public {
        (HookTokenV2 t,) = _underwaterPool(10_000, 25);
        vm.expectRevert(UnderwaterModule.NotKeeper.selector);
        uw.distribute(address(t), _list(alice));
        vm.prank(alice);
        vm.expectRevert();
        uw.setKeeper(alice);
        vm.prank(SAFE);
        (uint256 paid,) = uw.distribute(address(t), _list(alice));
        assertGt(paid, 0, "owner may run a round");
    }

    /// Curve: buys add what was spent, sells lower basis in proportion; fees fill the pot.
    function test_curveBasis() public {
        HookTokenV2 t = _launch(_one(uwId), _oneCfg(_cfg(300, 0, IVL, 10_000)), 0);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        uint256 b1 = _basis(t, alice);
        assertGt(b1, 9 ether, "paid minus fees and impact, valued at the opening price");
        assertLe(b1, 10 ether, "never more than paid");
        vm.prank(alice);
        pad.buy{value: 2 ether}(address(t), 0);
        uint256 b2 = _basis(t, alice);
        assertGt(b2, b1);
        assertLe(b2, 12 ether);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t), bal / 4, 0);
        assertApproxEqAbs(_basis(t, alice), b2 - (b2 + 3) / 4, 2, "a quarter sold: a quarter of the basis gone");
        uw.reconcile();
        assertGt(_pot(t), (12 ether * 300) / 10_000);
        assertEq(uw.accounted(address(0)), hook.claimable(address(uw), NATIVE));
    }

    /// Curve phase payout: alice bought after bob, bob sold out, so alice is underwater at the curve price.
    function test_curveDistribute() public {
        HookTokenV2 t = _launch(_one(uwId), _oneCfg(_cfg(300, 0, IVL, 10_000)), 0);
        vm.warp(vm.getBlockTimestamp() + IVL);
        vm.prank(bob);
        pad.buy{value: 20 ether}(address(t), 0);
        vm.warp(vm.getBlockTimestamp() + IVL); // bob's price holds an interval
        vm.prank(alice);
        pad.buy{value: 5 ether}(address(t), 0);
        uint256 bb = t.balanceOf(bob);
        vm.prank(bob);
        pad.sell(address(t), bb, 0);
        assertEq(_basis(t, bob), 0, "sold out: no basis");
        vm.warp(vm.getBlockTimestamp() + IVL);
        uw.reconcile();
        uint256 gap = _gap(t, alice);
        assertGt(gap, 0);
        uint256 pot = _pot(t);
        uint256 want = _maxPay(t, alice);
        if (want > pot) want = pot;
        assertEq(want, (gap * SHARE) / 10_000 < pot ? (gap * SHARE) / 10_000 : pot);
        (uint256 paid, uint256 n) = _dist(t, _list(alice, bob));
        assertEq(n, 1);
        assertEq(paid, want);
        assertEq(hook.claimable(alice, NATIVE), paid);
        assertEq(_pot(t), pot - paid);
    }

    /// Pool: router buys add basis, aggregator buys none, wallet-to-wallet moves carry none.
    function test_poolBasisRoutes() public {
        (HookTokenV2 t, PoolKey memory key) = _launchOne(uwId, _cfg(300, 0, IVL, 10_000));
        vm.warp(vm.getBlockTimestamp() + IVL);
        _routerBuy(alice, t, 10 ether);
        uint256 b1 = _basis(t, alice);
        assertGt(b1, 9 ether);
        assertLe(b1, 10 ether);
        agg.swap(key, true, -int256(5 ether));
        assertGt(t.balanceOf(address(agg)), 0);
        assertEq(_basis(t, address(agg)), 0, "aggregator buys add no basis");
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        t.transfer(carol, half);
        assertApproxEqAbs(_basis(t, alice), b1 - (b1 + 1) / 2, 2);
        assertEq(_basis(t, carol), 0, "received tokens carry no basis");
        vm.prank(carol);
        t.transfer(alice, half);
        assertApproxEqAbs(_basis(t, alice), b1 - (b1 + 1) / 2, 2);
    }

    /// A round pays at most maxGapShareBps of the gap; the payment comes off the basis; one round per interval;
    /// lifetime payouts stop at half of all basis ever added.
    function test_poolRoundsAndCaps() public {
        (HookTokenV2 t,) = _underwaterPool(10_000, 25);
        uint256 gap = _gap(t, alice);
        assertGt(gap, 0, "alice is underwater");
        uint256 basis = _basis(t, alice);
        uint256 pot = _pot(t);
        (uint256 paid, uint256 n) = _dist(t, _list(alice));
        assertEq(n, 1);
        assertEq(paid, Math.min((gap * SHARE) / 10_000, pot));
        assertEq(_basis(t, alice), basis - paid);
        assertEq(hook.claimable(alice, NATIVE), paid);
        assertEq(uw.accounted(address(0)), hook.claimable(address(uw), NATIVE));
        // the pool waits an interval for its next round
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(UnderwaterModule.TooSoon.selector, vm.getBlockTimestamp() + IVL));
        uw.distribute(address(t), _list(bob));
        // many rounds later: never more than half of what alice paid in
        uint256 total = paid;
        for (uint256 i; i < 40; ++i) {
            vm.warp(vm.getBlockTimestamp() + IVL);
            _routerBuy(carol, t, 20 ether); // refills the pot
            _routerSell(carol, t, t.balanceOf(carol));
            vm.warp(vm.getBlockTimestamp() + IVL);
            uw.reconcile();
            (paid,) = _dist(t, _list(alice));
            total += paid;
        }
        assertLe(total, 25 ether, "lifetime cap: 50% of 50 AVAX");
        assertEq(hook.claimable(alice, NATIVE), total);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        hook.claim(NATIVE, alice);
        assertEq(alice.balance - b0, total);
    }

    /// roundBps caps a round; two wallets split pro-rata to their gaps (below their own caps).
    function test_roundBudgetAndSplit() public {
        HookTokenV2 t = _launch(_one(uwId), _oneCfg(_cfg5(300, 0, IVL, 500, 5_000)), 0);
        _graduateN(t, 40, 0);
        vm.warp(vm.getBlockTimestamp() + IVL);
        _routerBuy(alice, t, 30 ether);
        _routerBuy(bob, t, 10 ether);
        for (uint256 i; i < 25; ++i) {
            _routerSell(_holder(i), t, t.balanceOf(_holder(i)));
        }
        vm.warp(vm.getBlockTimestamp() + IVL);
        uw.reconcile();
        uint256 pot = _pot(t);
        uint256 ga = _gap(t, alice);
        uint256 gb = _gap(t, bob);
        assertGt(ga, gb);
        (uint256 paid,) = _dist(t, _list(alice, bob));
        uint256 budget = (pot * 500) / 10_000;
        assertLe(paid, budget);
        uint256 pa = hook.claimable(alice, NATIVE);
        uint256 pb = hook.claimable(bob, NATIVE);
        assertLe(pa, ga / 2);
        assertLe(pb, gb / 2);
        if (pa < ga / 2 && pb < gb / 2) assertApproxEqRel(pa * gb, pb * ga, 1e12, "pro-rata to gaps");
    }

    function test_refusalsAndLimits() public {
        (HookTokenV2 t,) = _underwaterPool(10_000, 25);
        (address lo, address hi) = alice < bob ? (alice, bob) : (bob, alice);
        address[] memory l = new address[](2);
        (l[0], l[1]) = (hi, lo);
        vm.expectRevert(UnderwaterModule.NotSorted.selector);
        _dist(t, l);
        (l[0], l[1]) = (alice, alice);
        vm.expectRevert(UnderwaterModule.NotSorted.selector);
        _dist(t, l);
        vm.expectRevert(UnderwaterModule.BatchTooLarge.selector);
        _dist(t, new address[](101));
        vm.prank(keeper);
        vm.expectRevert(UnderwaterModule.UnknownToken.selector);
        uw.distribute(address(0xBEEF), _list(alice));
        // a fresh buy restarts the wallet's buy age
        _routerBuy(alice, t, 0.1 ether);
        assertEq(_gap(t, alice), 0);
        (uint256 paid,) = _dist(t, _list(alice));
        assertEq(paid, 0);
        assertEq(_gap(t, address(PM)), 0, "plumbing never counts");
    }

    /// A wallet holding less than minHoldBps is never paid.
    function test_minHold() public {
        HookTokenV2 t = _launch(_one(uwId), _oneCfg(_cfg(300, 100, IVL, 10_000)), 0);
        _graduateN(t, 40, 0);
        vm.warp(vm.getBlockTimestamp() + IVL);
        _routerBuy(alice, t, 0.5 ether); // far below 1% of the supply
        for (uint256 i; i < 10; ++i) {
            _routerSell(_holder(i), t, t.balanceOf(_holder(i)));
        }
        vm.warp(vm.getBlockTimestamp() + IVL);
        assertLt(t.balanceOf(alice), SUPPLY / 100);
        assertEq(_gap(t, alice), 0);
    }

    /// Buying into a pump books the fair value, not the pumped price: no fake gap once the pump is dumped.
    function test_buyIntoPumpBooksFairValue() public {
        HookTokenV2 t = _launch(_one(uwId), _oneCfg(_cfg(300, 0, IVL, 10_000)), 0);
        _graduateN(t, 40, 0);
        vm.warp(vm.getBlockTimestamp() + IVL);
        address c = makeAddr("pumper");
        vm.deal(c, 1_000 ether);
        _routerBuy(c, t, 900 ether); // pump
        _routerBuy(alice, t, 300 ether); // buys high, same second
        _routerSell(c, t, t.balanceOf(c)); // dump
        assertLt(_basis(t, alice), 300 ether / 2, "valued at the pre-pump price");
        vm.warp(vm.getBlockTimestamp() + IVL);
        uint256 gap = _gap(t, alice);
        (uint256 basis, uint256 value,,,) = uw.position(address(t), alice);
        assertLe(gap, basis / 20, "at most fee-sized");
        assertGt(value, 0);
    }

    /// A dump right before a round doesn't create gaps: the price must stay down for an interval (TWAP).
    function test_twapIgnoresLastMinuteDump() public {
        (HookTokenV2 t,) = _underwaterPool(10_000, 10);
        vm.warp(vm.getBlockTimestamp() + IVL); // the post-dump price held a full interval
        _routerBuy(carol, t, 0.1 ether); // a trade records it
        (,,, uint256 m0,) = uw.stats(address(t));
        uint256 g0 = _gap(t, alice);
        for (uint256 i = 30; i < 38; ++i) {
            _routerSell(_holder(i), t, t.balanceOf(_holder(i))); // big dump, same block
        }
        assertLt(uw.twapMarketCap(address(t)), m0 + 1);
        (,,, uint256 m1,) = uw.stats(address(t));
        assertApproxEqRel(m1, m0, 0.01e18, "priced at the interval average, not the dump");
        assertApproxEqRel(_gap(t, alice), g0, 0.01e18);
        // once the low price has held for a few intervals it is real
        vm.warp(vm.getBlockTimestamp() + 3 * IVL);
        assertGt(_gap(t, alice), g0);
    }

    function test_rescueAfterDisable() public {
        (HookTokenV2 t,) = _underwaterPool(10_000, 5);
        uint256 pot = _pot(t);
        modules.disable(uwId);
        vm.expectRevert(UnderwaterModule.ModuleDisabled.selector);
        _dist(t, _list(alice));
        uw.rescue(address(t));
        assertEq(hook.claimable(creator, NATIVE), pot);
        assertEq(_pot(t), 0);
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_payNeverAboveCaps(uint256 dumpers, uint16 roundBps, uint256 buy, uint16 share) public {
        roundBps = uint16(bound(roundBps, 500, 10_000));
        share = uint16(bound(share, 1, 5_000));
        HookTokenV2 t = _launch(_one(uwId), _oneCfg(_cfg5(300, 0, IVL, roundBps, share)), 0);
        _graduateN(t, 40, 0);
        vm.warp(vm.getBlockTimestamp() + IVL);
        _routerBuy(alice, t, bound(buy, 1 ether, 80 ether));
        _routerBuy(bob, t, 3 ether);
        dumpers = bound(dumpers, 0, 35);
        for (uint256 i; i < dumpers; ++i) {
            _routerSell(_holder(i), t, t.balanceOf(_holder(i)));
        }
        vm.warp(vm.getBlockTimestamp() + IVL);
        uw.reconcile();
        uint256 pot = _pot(t);
        uint256 ga = _gap(t, alice);
        uint256 gb = _gap(t, bob);
        (uint256 paid,) = _dist(t, _list(alice, bob));
        assertLe(paid, (pot * roundBps) / 10_000);
        assertLe(hook.claimable(alice, NATIVE), (ga * share) / 10_000);
        assertLe(hook.claimable(bob, NATIVE), (gb * share) / 10_000);
        assertEq(_pot(t), pot - paid);
        assertEq(uw.accounted(address(0)), hook.claimable(address(uw), NATIVE));
    }
}
