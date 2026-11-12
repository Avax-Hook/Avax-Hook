// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {GraduatedSellCapModule} from "../../contracts/v2/modules/GraduatedSellCapModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// Isolated: each top-level call is its own transaction (sells of one transaction count together).
/// forge-config: default.isolate = true
contract GraduatedSellCapModuleTest is NewModulesBase {
    GraduatedSellCapModule gs;
    uint32 gsId;
    HookTokenV2 t;
    PoolKey key;
    address whale;

    uint256 constant SMALL = 5_000_000 ether; // 0.5% bag
    uint256 constant HI = 10_000_000 ether; // 1% cap for small bags
    uint256 constant WHALE = 30_000_000 ether; // 3% bag
    uint256 constant LO = 1_000_000 ether; // 0.1% floor cap

    function setUp() public override {
        super.setUp();
        gs = new GraduatedSellCapModule(address(hook));
        gsId = modules.addModule(address(gs), '{"name":"Graduated sell caps"}');
        (t, key) = _launchOne(gsId, _cfg(50, 100, 300, 10, 0));
        // after graduation: gather ten curve bags into one whale (wallet-to-wallet moves are never limited)
        whale = _holder(0);
        for (uint256 i = 1; i < 10; ++i) {
            address w = _holder(i);
            uint256 b = t.balanceOf(w);
            vm.prank(w);
            t.transfer(whale, b);
        }
    }

    function _cfg(uint16 smallBag, uint16 smallCap, uint16 whaleBag, uint16 floorCap, uint32 duration)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(GraduatedSellCapModule.Config(smallBag, smallCap, whaleBag, floorCap, duration));
    }

    function test_capabilities() public view {
        assertEq(gs.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS);
        assertEq(gs.conflictGroups(), ModuleCaps.GROUP_SELL_CAP);
        assertTrue(t.transferRules());
    }

    function test_capShape() public view {
        assertEq(gs.capForBag(address(t), 0), HI);
        assertEq(gs.capForBag(address(t), SMALL), HI);
        assertEq(gs.capForBag(address(t), WHALE), LO);
        assertEq(gs.capForBag(address(t), SUPPLY), LO);
        // 2% bag: 1% - 0.9% * (1.5 / 2.5) = 0.46%
        assertEq(gs.capForBag(address(t), 20_000_000 ether), 4_600_000 ether);
        (uint256 cap, bool active) = gs.sellCapOf(address(t), whale);
        assertEq(cap, LO);
        assertTrue(active);
    }

    function test_whaleSellsInSteps() public {
        assertGt(t.balanceOf(whale), WHALE);
        bytes memory err = _sellError(whale, t, 2 * LO);
        assertTrue(_has(err, GraduatedSellCapModule.SellCapExceeded.selector));
        _routerSell(whale, t, LO);
        _routerSell(whale, t, LO); // next transaction, next step
    }

    function test_midBagLinearCap() public {
        address w = carol; // two late curve bags: ~1.7%
        for (uint256 i = 25; i < 27; ++i) {
            uint256 b = t.balanceOf(_holder(i));
            vm.prank(_holder(i));
            t.transfer(w, b);
        }
        uint256 bag = t.balanceOf(w);
        assertGt(bag, SMALL);
        assertLt(bag, WHALE);
        uint256 cap = gs.capForBag(address(t), bag);
        assertLt(cap, HI);
        assertGt(cap, LO);
        bytes memory err = _sellError(w, t, cap + 1);
        assertTrue(_has(err, GraduatedSellCapModule.SellCapExceeded.selector));
        _routerSell(w, t, cap);
    }

    function test_smallBagSellsEverything() public {
        uint256 a = _routerBuy(alice, t, 10 ether); // well under 0.5%
        assertLt(a, SMALL);
        _routerSell(alice, t, a);
    }

    /// The bag is read once, before the transaction's first sell, and every sell of the transaction counts.
    function test_splitSellsInOneTxCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        uint256 bal = t.balanceOf(whale);
        vm.prank(whale);
        t.transfer(address(m), bal);
        try m.sellTwice(address(t), 600_000 ether, 600_000 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, GraduatedSellCapModule.SellCapExceeded.selector));
        }
        m.sellTwice(address(t), 400_000 ether, 400_000 ether);
    }

    /// Claims bypass guard (2026-11-12): while the cap applies (here forever) an aggregator selling on the
    /// PoolManager directly is refused outright with RouterOnly, whatever the bag (it could otherwise sell from
    /// PoolManager claims the cap never sees). The router sells the same bag under the floor cap.
    function test_aggregatorSellsAsItsContract() public {
        uint256 bal = t.balanceOf(whale);
        vm.prank(whale);
        t.approve(address(agg), bal);
        try agg.sellFrom(key, address(t), whale, 4_000_000 ether) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        assertEq(t.balanceOf(whale), bal, "nothing moved");
        _sellReverts(whale, t, 50_000_000 ether); // the whale bag's floor cap, through the router
    }

    function test_transfersNeverLimited() public {
        uint256 bal = t.balanceOf(whale);
        vm.prank(whale);
        t.transfer(carol, bal);
        assertEq(t.balanceOf(carol), bal);
    }

    function test_curvePhase() public {
        HookTokenV2 t2 = _launch(_one(gsId), _oneCfg(_cfg(50, 100, 300, 10, 0)), 0);
        vm.prank(alice);
        pad.buy{value: 20 ether}(address(t2), 0);
        assertGt(t2.balanceOf(alice), WHALE);
        vm.prank(alice);
        try pad.sell(address(t2), 2 * LO, 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, GraduatedSellCapModule.SellCapExceeded.selector));
        }
        vm.prank(alice);
        pad.sell(address(t2), LO, 0);
    }

    function test_durationEnds() public {
        (HookTokenV2 t2,) = _launchOne(gsId, _cfg(50, 100, 300, 10, 1 days));
        address w = _holder(0);
        uint256 bal = t2.balanceOf(w);
        bytes memory err = _sellError(w, t2, bal);
        assertTrue(_has(err, GraduatedSellCapModule.SellCapExceeded.selector));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (, bool active) = gs.sellCapOf(address(t2), w);
        assertFalse(active);
        vm.startPrank(w);
        t2.approve(address(router), bal);
        router.sell(address(t2), bal, 0, block.timestamp, "");
        vm.stopPrank();
    }

    function test_configBounds() public {
        vm.expectRevert();
        gs.validateConfig(_cfg(0, 100, 300, 10, 0));
        vm.expectRevert();
        gs.validateConfig(_cfg(5_001, 100, 6_000, 10, 0));
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 100, 50, 10, 0)); // whale bag must exceed small bag
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 100, 10_001, 10, 0));
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 0, 300, 0, 0));
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 5_001, 300, 10, 0));
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 100, 300, 101, 0)); // floor over the small cap
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 100, 300, 0, 0));
        vm.expectRevert();
        gs.validateConfig(_cfg(50, 100, 300, 10, 365 days + 1));
        gs.validateConfig(_cfg(1, 1, 2, 1, 365 days));
        gs.validateConfig(_cfg(5_000, 5_000, 10_000, 5_000, 0));
    }

    function test_onlyHook() public {
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        gs.onTransfer(_id(key), address(t), alice, alice, address(PM), 1);
    }

    /// Bigger bags never get a bigger cap; the cap stays within [floor, small cap].
    function testFuzz_capShrinksWithBag(uint256 a, uint256 b) public view {
        a = bound(a, 0, SUPPLY);
        b = bound(b, a, SUPPLY);
        uint256 ca = gs.capForBag(address(t), a);
        uint256 cb = gs.capForBag(address(t), b);
        assertLe(cb, ca);
        assertGe(cb, LO);
        assertLe(ca, HI);
    }
}
