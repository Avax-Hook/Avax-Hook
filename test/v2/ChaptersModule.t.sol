// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {ChaptersModule} from "../../contracts/v2/modules/ChaptersModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// Isolated: each top-level call is its own transaction (the cap leaves the current tx's volume out).
/// forge-config: default.isolate = true
contract ChaptersModuleTest is NewModulesBase {
    ChaptersModule ch;
    uint32 chId;
    HookTokenV2 t;
    PoolKey key;

    uint256 constant CHAPTER = 1_000_000_000 ether; // 1B tokens of volume per chapter
    uint256 constant CAP0 = 10_000_000 ether; // 1%

    function setUp() public override {
        super.setUp();
        ch = new ChaptersModule(address(hook));
        chId = modules.addModule(address(ch), '{"name":"Chapters"}');
        // the cap binds curve buyers too: fill the curve with buys under 1%
        (t, key) = _launchCapped(chId, _cfg(100, 1_600, uint128(CHAPTER)), 9_000_000 ether, 0);
    }

    function _cfg(uint16 start, uint16 max, uint128 chapter) internal pure returns (bytes memory) {
        return abi.encode(ChaptersModule.Config(start, max, chapter));
    }

    /// Adds `amount` of volume as if a sell of that size ran (own transaction).
    function _pump(uint256 amount) internal {
        IHookModule.SwapContext memory c;
        c.poolId = _id(key);
        c.token = address(t);
        c.amountIn = amount;
        vm.prank(address(hook));
        ch.onAfterSwap(c);
    }

    function _vol() internal view returns (uint256 v) {
        (,, v,) = ch.currentCap(address(t));
    }

    function _cap() internal view returns (uint256 c) {
        (c,,,) = ch.currentCap(address(t));
    }

    function test_capabilities() public view {
        assertEq(ch.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER);
        assertEq(ch.conflictGroups(), ModuleCaps.GROUP_HOLDING_CAP);
        assertTrue(t.transferRules());
    }

    function test_curveVolumeCountedAndCurveBuysCapped() public {
        HookTokenV2 t2 = _launch(_one(chId), _oneCfg(_cfg(100, 1_600, uint128(CHAPTER))), 0);
        vm.prank(alice);
        try pad.buy{value: 20 ether}(address(t2), 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, ChaptersModule.MaxWalletExceeded.selector));
        }
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t2), 0);
        (uint256 cap, uint256 chapter, uint256 v, uint256 next) = ch.currentCap(address(t2));
        assertEq(cap, CAP0);
        assertEq(chapter, 0);
        assertEq(v, t2.balanceOf(alice)); // tokens received on the buy
        assertEq(next, CHAPTER);
        // a curve sell adds the tokens sold
        vm.prank(alice);
        pad.sell(address(t2), v / 2, 0);
        (,, uint256 v2,) = ch.currentCap(address(t2));
        assertEq(v2, v + v / 2);
    }

    function test_poolTradesAddVolume_routerAndAggregator() public {
        uint256 v0 = _vol();
        assertGt(v0, 0);
        assertLt(v0, CHAPTER);
        uint256 got = _routerBuy(alice, t, 10 ether);
        assertEq(_vol(), v0 + got);
        _routerSell(alice, t, got / 2);
        assertEq(_vol(), v0 + got + got / 2);
        // a contract buying through the router counts too; a direct PoolManager buy is refused while capped
        uint256 v1 = _vol();
        MultiSwapper ms = new MultiSwapper(router);
        ms.buyTwice{value: 4 ether}(address(t), 2 ether, 2 ether);
        assertEq(_vol(), v1 + t.balanceOf(address(ms)));
        _aggSwapRouterOnly(key, true, -int256(5 ether));
        assertEq(_vol(), v1 + t.balanceOf(address(ms)), "refused swap adds nothing");
    }

    function test_capDoublesEachChapterThenLifts() public {
        assertEq(_cap(), CAP0);
        bytes memory err = _buyError(alice, t, 100 ether); // ~1.5%
        assertTrue(_has(err, ChaptersModule.MaxWalletExceeded.selector));

        _pump(CHAPTER - _vol()); // chapter 1: 2%
        assertEq(_cap(), 2 * CAP0);
        uint256 a = _routerBuy(alice, t, 100 ether);
        assertGt(a, CAP0);
        assertLe(a, 2 * CAP0);

        _pump(CHAPTER); // chapter 2: 4%
        assertEq(_cap(), 4 * CAP0);
        _pump(CHAPTER); // chapter 3: 8%
        assertEq(_cap(), 8 * CAP0);
        _pump(CHAPTER); // chapter 4: 16% reaches the max -> no cap
        (uint256 cap, uint256 chapter,, uint256 next) = ch.currentCap(address(t));
        assertEq(cap, 0);
        assertEq(chapter, 4);
        assertEq(next, 0);
        uint256 b = _routerBuy(bob, t, 1_500 ether);
        assertGt(b, 8 * CAP0);
    }

    /// A buy can't open the chapter it needs by itself: the cap uses the volume before its transaction.
    function test_ownTransactionVolumeLeftOut() public {
        _pump(CHAPTER - _vol() - 1_000_000 ether); // 1M short of chapter 1
        bytes memory err = _buyError(alice, t, 100 ether); // its own ~1.5% would cross the chapter
        assertTrue(_has(err, ChaptersModule.MaxWalletExceeded.selector));
        assertEq(_cap(), CAP0);
        _pump(1_000_000 ether);
        assertEq(_cap(), 2 * CAP0);
        _routerBuy(alice, t, 100 ether); // next transaction: fits
    }

    function test_transfersCapped_sellsAndSendsFree() public {
        address h0 = _holder(0);
        address h1 = _holder(1);
        uint256 b0 = t.balanceOf(h0);
        uint256 b1 = t.balanceOf(h1);
        assertGt(b0 + b1, CAP0);
        vm.prank(h0);
        vm.expectRevert(abi.encodeWithSelector(ChaptersModule.MaxWalletExceeded.selector, h1, b0 + b1, CAP0));
        t.transfer(h1, b0);
        vm.prank(h0);
        t.transfer(carol, b0 / 2); // under the cap
        _routerSell(h1, t, b1); // selling is never limited
        vm.prank(h0);
        t.transfer(DEAD, 1 ether);
    }

    /// Claims bypass guard (2026-11-12): while there is a cap, aggregator buys on the PoolManager are refused
    /// with RouterOnly, big or small; the same small buy through the router passes the cap.
    function test_aggregatorCountsAsWallet() public {
        _aggSwapRouterOnly(key, true, -int256(150 ether));
        _aggSwapRouterOnly(key, true, -int256(5 ether));
        _routerBuy(alice, t, 5 ether);
    }

    function test_creatorNotExempt() public {
        vm.deal(creator, 1_000 ether);
        bytes memory err = _buyError(creator, t, 100 ether);
        assertTrue(_has(err, ChaptersModule.MaxWalletExceeded.selector));
    }

    function test_configBounds() public {
        vm.expectRevert();
        ch.validateConfig(_cfg(9, 1_000, uint128(CHAPTER)));
        vm.expectRevert();
        ch.validateConfig(_cfg(5_001, 10_000, uint128(CHAPTER)));
        vm.expectRevert();
        ch.validateConfig(_cfg(100, 100, uint128(CHAPTER))); // max must exceed start
        vm.expectRevert();
        ch.validateConfig(_cfg(100, 10_001, uint128(CHAPTER)));
        vm.expectRevert();
        ch.validateConfig(_cfg(100, 1_000, 999_999 ether));
        vm.expectRevert();
        ch.validateConfig(_cfg(100, 1_000, 10_000_000_001 ether));
        ch.validateConfig(_cfg(10, 10_000, 1_000_000 ether));
        ch.validateConfig(_cfg(5_000, 10_000, 10_000_000_000 ether));
    }

    function test_onlyHook() public {
        IHookModule.SwapContext memory c;
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        ch.onAfterSwap(c);
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        ch.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }

    /// cap = start · 2^chapter until it reaches max, then none.
    function testFuzz_capFollowsChapters(uint256 a, uint256 b) public {
        a = bound(a, 1, 3 * CHAPTER);
        b = bound(b, 1, 3 * CHAPTER);
        _pump(a);
        _pump(b);
        (uint256 cap, uint256 chapter, uint256 v,) = ch.currentCap(address(t));
        assertEq(chapter, v / CHAPTER);
        uint256 bps = 100 << chapter;
        assertEq(cap, bps >= 1_600 ? 0 : (SUPPLY * bps) / 10_000);
    }
}
