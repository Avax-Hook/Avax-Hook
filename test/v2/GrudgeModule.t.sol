// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {GrudgeModule} from "../../contracts/v2/modules/GrudgeModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// Isolated: each top-level call is its own transaction (a dump is measured per transaction).
/// forge-config: default.isolate = true
contract GrudgeModuleTest is NewModulesBase {
    GrudgeModule gm;
    uint32 gmId;
    HookTokenV2 t;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        gm = new GrudgeModule(address(hook));
        gmId = modules.addModule(address(gm), '{"name":"The grudge"}');
        // a dump = 50% of the bag in one transaction; 1 hour, doubling up to 4 hours; buy ban
        (t, key) = _launchOne(gmId, _cfg(5_000, 1 hours, 4 hours, 0, 0, 0));
    }

    function _cfg(uint16 dump, uint32 time, uint32 max, uint8 mode, uint16 tax, uint16 cap)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(GrudgeModule.Config(dump, time, max, mode, tax, cap));
    }

    function _until(HookTokenV2 tok, address w) internal view returns (uint256 u) {
        (u,,) = gm.grudgeOf(address(tok), w);
    }

    function _count(HookTokenV2 tok, address w) internal view returns (uint256 c) {
        (, c,) = gm.grudgeOf(address(tok), w);
    }

    function _dump(HookTokenV2 tok, address w) internal {
        _routerSell(w, tok, (tok.balanceOf(w) * 6) / 10);
    }

    function test_capabilities() public view {
        assertEq(gm.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER);
        assertEq(gm.conflictGroups(), 0);
        assertTrue(t.transferRules());
    }

    function test_dumpBansBuys_untilItExpires() public {
        address h = _holder(5);
        _dump(t, h);
        uint256 now_ = vm.getBlockTimestamp();
        (uint256 until, uint256 count, bool active) = gm.grudgeOf(address(t), h);
        assertEq(until, now_ + 1 hours);
        assertEq(count, 1);
        assertTrue(active);
        bytes memory err = _buyError(h, t, 1 ether);
        assertTrue(_has(err, GrudgeModule.BuyBanned.selector));
        // receiving from a wallet is fine, and selling is never blocked
        vm.prank(_holder(6));
        t.transfer(h, 1 ether);
        _routerSell(h, t, 1 ether);
        assertEq(_count(t, h), 1);
        vm.warp(now_ + 1 hours);
        (,, active) = gm.grudgeOf(address(t), h);
        assertFalse(active);
        _routerBuy(h, t, 1 ether);
    }

    function test_repeatsDoubleUpToMax() public {
        address h = _holder(5);
        uint256 now_ = vm.getBlockTimestamp();
        assertEq(gm.nextGrudgeTime(address(t), h), 1 hours);
        _dump(t, h);
        assertEq(gm.nextGrudgeTime(address(t), h), 2 hours);
        _dump(t, h); // dumping again while grudged: still allowed, longer grudge
        assertEq(_until(t, h), now_ + 2 hours);
        _dump(t, h);
        assertEq(_until(t, h), now_ + 4 hours);
        assertEq(gm.nextGrudgeTime(address(t), h), 4 hours); // capped
        _dump(t, h);
        assertEq(_until(t, h), now_ + 4 hours);
        assertEq(_count(t, h), 4);
    }

    function test_smallSellIsNoDump() public {
        address h = _holder(5);
        _routerSell(h, t, (t.balanceOf(h) * 4) / 10);
        assertEq(_count(t, h), 0);
        _routerSell(h, t, (t.balanceOf(h) * 4) / 10); // separate transaction, its own bag
        assertEq(_count(t, h), 0);
        _routerBuy(h, t, 1 ether);
    }

    function test_splitSellsInOneTxCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        uint256 bal = t.balanceOf(_holder(5));
        vm.prank(_holder(5));
        t.transfer(address(m), bal);
        m.sellTwice(address(t), (bal * 3) / 10, (bal * 3) / 10);
        assertEq(_count(t, address(m)), 1);
    }

    function test_buyThenSellInOneTxIsNoDump() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 10 ether);
        m.buyThenSell{value: 5 ether}(address(t), 5 ether);
        assertEq(_count(t, address(m)), 0);
    }

    /// Aggregators that pull the tokens in first: neither the holder nor the aggregator is grudged.
    function test_aggregatorSellsNotSeen() public {
        address h = _holder(5);
        uint256 bal = t.balanceOf(h);
        vm.prank(h);
        t.approve(address(agg), bal);
        agg.sellFrom(key, address(t), h, bal);
        assertEq(_count(t, h), 0);
        assertEq(_count(t, address(agg)), 0);
        agg.swap(key, true, -int256(1 ether)); // aggregator buys keep working
    }

    function test_creatorNotExempt() public {
        address h = _holder(5);
        uint256 bal = t.balanceOf(h);
        vm.prank(h);
        t.transfer(creator, bal);
        _dump(t, creator);
        bytes memory err = _buyError(creator, t, 1 ether);
        assertTrue(_has(err, GrudgeModule.BuyBanned.selector));
    }

    function test_mode1_buyTaxToLiquidity() public {
        (HookTokenV2 t2, PoolKey memory k2) = _launchOne(gmId, _cfg(5_000, 1 hours, 4 hours, 1, 1_000, 0));
        address h = _holder(5);
        _dump(t2, h);
        assertEq(_count(t2, h), 1);
        IHookModule.SwapContext memory c;
        c.poolId = _id(k2);
        c.token = address(t2);
        c.isBuy = true;
        c.amountIn = 10 ether;
        c.trader = h;
        vm.prank(address(hook));
        (, IHookModule.Credit[] memory cr) = gm.onBeforeSwap(c);
        assertEq(cr.length, 1);
        assertEq(cr[0].to, ModuleCaps.LP_DONATE);
        assertEq(cr[0].amount, 1 ether);
        c.trader = bob; // not grudged
        vm.prank(address(hook));
        (, cr) = gm.onBeforeSwap(c);
        assertEq(cr.length, 0);
        c.trader = address(0); // aggregator: unknown buyer, refused while a grudge is live (claims bypass guard)
        vm.prank(address(hook));
        vm.expectRevert(ROUTER_ONLY);
        gm.onBeforeSwap(c);
        c.phase = ModuleCaps.PHASE_CURVE; // (never on the curve: the trader is always known there; untaxed if not)
        vm.prank(address(hook));
        (, cr) = gm.onBeforeSwap(c);
        assertEq(cr.length, 0);
        c.phase = ModuleCaps.PHASE_POOL;
        // end to end: the grudged buyer gets ~10% less
        uint256 snap = vm.snapshotState();
        uint256 taxed = _routerBuy(h, t2, 10 ether);
        vm.revertToState(snap);
        uint256 full = _routerBuy(bob, t2, 10 ether);
        assertLt(taxed, (full * 92) / 100);
        assertGt(taxed, (full * 85) / 100);
    }

    function test_mode2_holdingCapWhileGrudged() public {
        (HookTokenV2 t2,) = _launchOne(gmId, _cfg(5_000, 1 hours, 4 hours, 2, 0, 50));
        address h = _holder(5);
        _dump(t2, h);
        uint256 cap = 5_000_000 ether;
        assertGt(t2.balanceOf(h), cap);
        uint256 hb = t2.balanceOf(h);
        vm.prank(_holder(6));
        vm.expectRevert(abi.encodeWithSelector(GrudgeModule.GrudgeCapExceeded.selector, h, hb + 1, cap));
        t2.transfer(h, 1);
        _routerSell(h, t2, t2.balanceOf(h) - 3_000_000 ether);
        _routerBuy(h, t2, 1 ether); // under the cap: fine
        vm.prank(_holder(6));
        t2.transfer(h, 1 ether);
    }

    function test_curvePhase() public {
        HookTokenV2 t2 = _launch(_one(gmId), _oneCfg(_cfg(5_000, 1 hours, 4 hours, 0, 0, 0)), 0);
        vm.prank(alice);
        pad.buy{value: 4 ether}(address(t2), 0);
        uint256 bal = t2.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t2), (bal * 8) / 10, 0);
        assertEq(_count(t2, alice), 1);
        vm.prank(alice);
        try pad.buy{value: 1 ether}(address(t2), 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, GrudgeModule.BuyBanned.selector));
        }
        uint256 rest = t2.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t2), rest, 0); // selling stays open
    }

    function test_configBounds() public {
        vm.expectRevert();
        gm.validateConfig(_cfg(999, 1 hours, 4 hours, 0, 0, 0));
        vm.expectRevert();
        gm.validateConfig(_cfg(10_001, 1 hours, 4 hours, 0, 0, 0));
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 59, 4 hours, 0, 0, 0));
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 5 hours, 4 hours, 0, 0, 0)); // first grudge over the max
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 30 days + 1, 0, 0, 0));
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 3, 0, 0));
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 1, 0, 0)); // tax mode needs a tax
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 1, 2_501, 0));
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 0, 100, 0)); // tax without tax mode
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 2, 0, 0)); // cap mode needs a cap
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 2, 0, 5_001));
        vm.expectRevert();
        gm.validateConfig(_cfg(5_000, 1 hours, 4 hours, 1, 100, 50)); // cap without cap mode
        gm.validateConfig(_cfg(1_000, 60, 30 days, 1, 2_500, 0));
        gm.validateConfig(_cfg(10_000, 30 days, 30 days, 2, 0, 5_000));
    }

    function test_onlyHook() public {
        IHookModule.SwapContext memory c;
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        gm.onBeforeSwap(c);
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        gm.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }

    /// The nth grudge lasts grudgeTime · 2^(n−1), never more than the max.
    function testFuzz_grudgeLengths(uint8 n) public {
        n = uint8(bound(n, 1, 12));
        address h = _holder(3);
        uint256 dur;
        for (uint256 i = 1; i <= n; ++i) {
            dur = gm.nextGrudgeTime(address(t), h);
            uint256 expect = (uint256(1 hours) << (i - 1));
            assertEq(dur, expect > 4 hours ? 4 hours : expect);
            uint256 bal = t.balanceOf(h);
            if ((bal * 6) / 10 < gm.MIN_DUMP()) return;
            _dump(t, h);
            assertEq(_count(t, h), i);
            assertLe(_until(t, h), vm.getBlockTimestamp() + 4 hours);
        }
    }
}
