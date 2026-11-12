// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {ConvictionCapModule} from "../../contracts/v2/modules/ConvictionCapModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// Isolated: each top-level call is its own transaction (buys of one transaction count together).
/// forge-config: default.isolate = true
contract ConvictionCapModuleTest is NewModulesBase {
    ConvictionCapModule cc;
    uint32 ccId;
    HookTokenV2 t;
    PoolKey key;

    uint256 constant START = 5_000_000 ether; // 0.5%
    uint256 constant CEILING = 20_000_000 ether; // 2%

    function setUp() public override {
        super.setUp();
        cc = new ConvictionCapModule(address(hook));
        ccId = modules.addModule(address(cc), '{"name":"Conviction cap"}');
        // 0.5% for a fresh wallet, +0.5% per day held, 2% ceiling, forever; curve buys under 0.5%
        (t, key) = _launchCapped(ccId, _cfg(50, 50, 1 days, 200, 0), 4_500_000 ether, 0);
    }

    function _cfg(uint16 start, uint16 growth, uint32 period, uint16 ceiling, uint32 duration)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(ConvictionCapModule.Config(start, growth, period, ceiling, duration));
    }

    function _capOf(address w) internal view returns (uint256 c) {
        (c,,) = cc.capOf(address(t), w);
    }

    function test_capabilities() public view {
        assertEq(cc.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY); // LP-removal allowance
        assertEq(cc.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
        assertTrue(t.transferRules());
    }

    function test_freshWalletGetsStartCap() public {
        (uint256 cap, uint256 since, bool active) = cc.capOf(address(t), alice);
        assertEq(cap, START);
        assertEq(since, 0);
        assertTrue(active);
        bytes memory err = _buyError(alice, t, 60 ether); // ~1%
        assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
        uint256 a = _routerBuy(alice, t, 10 ether);
        assertLe(a, START);
        (, since,) = cc.capOf(address(t), alice);
        assertEq(since, vm.getBlockTimestamp()); // clock starts at the first receive
    }

    function test_capGrowsWithHolding_resetBySellAndSend() public {
        _routerBuy(alice, t, 10 ether);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1 days);
        assertEq(_capOf(alice), 2 * START);
        vm.warp(t0 + 2 days);
        assertEq(_capOf(alice), 3 * START);
        vm.warp(t0 + 30 days);
        assertEq(_capOf(alice), CEILING); // ceiling
        uint256 a = _routerBuy(alice, t, 60 ether); // ~1%: fits now
        assertGt(a, START);
        // a sell restarts the clock
        _routerSell(alice, t, 1 ether);
        assertEq(_capOf(alice), START);
        bytes memory err = _buyError(alice, t, 60 ether);
        assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
        // so does a send; the receiver's clock starts on its first receive and isn't reset by more receipts
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(_capOf(alice), 3 * START);
        vm.prank(alice);
        t.transfer(bob, 1 ether);
        assertEq(_capOf(alice), START);
        (, uint256 bobSince,) = cc.capOf(address(t), bob);
        assertEq(bobSince, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        t.transfer(bob, 1 ether);
        assertEq(_capOf(bob), 2 * START);
    }

    function test_emptyWalletStopsClock() public {
        uint256 a = _routerBuy(alice, t, 10 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _routerSell(alice, t, a);
        (, uint256 since,) = cc.capOf(address(t), alice);
        assertEq(since, 0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(_capOf(alice), START); // holding nothing doesn't age the wallet
    }

    function test_splitBuysInOneTxCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 100 ether);
        // two ~0.35% buys: each fits the 0.5% cap, together they don't
        try m.buyTwice{value: 40 ether}(address(t), 20 ether, 20 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
        }
        _routerBuy(carol, t, 20 ether);
        _routerBuy(carol, t, 1 ether); // next transaction: a fresh per-buy budget
    }

    /// Claims bypass guard (2026-11-12): the cap runs forever here, so aggregator buys on the PoolManager are
    /// always refused with RouterOnly; a contract buying through the router is still its own wallet under the cap.
    function test_aggregatorIsTheWallet() public {
        _aggSwapRouterOnly(key, true, -int256(60 ether));
        _aggSwapRouterOnly(key, true, -int256(10 ether));
        MultiSwapper ms = new MultiSwapper(router);
        vm.expectRevert();
        ms.buyTwice{value: 60 ether}(address(t), 30 ether, 30 ether);
        ms.buyTwice{value: 10 ether}(address(t), 5 ether, 5 ether);
    }

    function test_creatorNotExempt() public {
        bytes memory err = _buyError(creator, t, 60 ether);
        assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
    }

    function test_curvePhase() public {
        HookTokenV2 t2 = _launch(_one(ccId), _oneCfg(_cfg(50, 50, 1 days, 200, 0)), 0);
        vm.prank(alice);
        try pad.buy{value: 20 ether}(address(t2), 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
        }
        vm.prank(alice);
        pad.buy{value: 0.5 ether}(address(t2), 0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        (uint256 cap,,) = cc.capOf(address(t2), alice);
        assertEq(cap, CEILING);
        vm.prank(alice);
        pad.buy{value: 2 ether}(address(t2), 0); // > 0.5%, under 2%
        // a curve sell restarts the clock
        vm.prank(alice);
        pad.sell(address(t2), 1 ether, 0);
        (cap,,) = cc.capOf(address(t2), alice);
        assertEq(cap, START);
    }

    function test_durationEnds() public {
        (HookTokenV2 t2,) = _launchCapped(ccId, _cfg(50, 50, 1 days, 200, 1 days), 4_500_000 ether, 0);
        bytes memory err = _buyError(alice, t2, 60 ether);
        assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (,, bool active) = cc.capOf(address(t2), alice);
        assertFalse(active);
        _routerBuy(alice, t2, 200 ether);
    }

    function test_configBounds() public {
        vm.expectRevert();
        cc.validateConfig(_cfg(0, 50, 1 days, 200, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(1_001, 50, 1 days, 2_000, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 0, 1 days, 200, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 1_001, 1 days, 200, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 50, 59, 200, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 50, 30 days + 1, 200, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 50, 1 days, 49, 0)); // ceiling under start
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 50, 1 days, 5_001, 0));
        vm.expectRevert();
        cc.validateConfig(_cfg(50, 50, 1 days, 200, 365 days + 1));
        cc.validateConfig(_cfg(1, 1, 60, 1, 365 days));
        cc.validateConfig(_cfg(1_000, 1_000, 30 days, 5_000, 0));
    }

    function test_onlyHook() public {
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        cc.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }

    /// cap = min(ceiling, start + growth · held / period), never below start.
    function testFuzz_capCurve(uint256 held) public {
        held = bound(held, 0, 400 days);
        _routerBuy(alice, t, 1 ether);
        vm.warp(vm.getBlockTimestamp() + held);
        uint256 bps = 50 + (50 * held) / 1 days;
        if (bps > 200) bps = 200;
        assertEq(_capOf(alice), (SUPPLY * bps) / 10_000);
    }
}
