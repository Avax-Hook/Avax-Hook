// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookZap} from "../../contracts/v2/AvaxHookZap.sol";
import {AvaxHookLimitOrders} from "../../contracts/v2/AvaxHookLimitOrders.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

/// Refuses AVAX, like a maker contract without `receive`.
contract NoReceive {
    function place(AvaxHookLimitOrders lo, address token, uint256 minOut) external payable returns (uint256) {
        return lo.place{value: msg.value}(token, true, msg.value - lo.keeperFee(), minOut, block.timestamp + 1 days);
    }

    function cancel(AvaxHookLimitOrders lo, uint256 id) external {
        lo.cancel(id);
    }
}

contract AvaxHookLimitOrdersTest is V1PortBase {
    address constant TREASURY = address(0x7EA5);
    uint16 constant FEE = 10; // 0.1%
    uint88 constant KFEE = 0.003 ether;

    AvaxHookZap zap;
    AvaxHookLimitOrders lo;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        address[] memory neutral = new address[](2);
        (neutral[0], neutral[1]) = (address(burn), address(antiSnipe));
        zap = new AvaxHookZap(router, neutral, SAFE);
        lo = new AvaxHookLimitOrders(zap, FEE, KFEE, TREASURY, SAFE);
    }

    function _token() internal returns (HookTokenV2 t) {
        (t,) = _one(burnId, _burnCfg(50));
    }

    /// Tokens `amt` AVAX buys right now (a quote run in a snapshot, so nothing moves).
    function _quoteBuy(HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _routerBuy(bob, t, amt);
        vm.revertToState(snap);
    }

    function _quoteSell(HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        deal(address(t), bob, amt);
        out = _routerSell(bob, t, amt);
        vm.revertToState(snap);
    }

    function _placeBuy(HookTokenV2 t, uint256 amt, uint256 minOut) internal returns (uint256 id) {
        vm.deal(alice, amt + KFEE);
        vm.prank(alice);
        id = lo.place{value: amt + KFEE}(address(t), true, amt, minOut, block.timestamp + 1 days);
    }

    function _placeSell(HookTokenV2 t, uint256 amt, uint256 minOut) internal returns (uint256 id) {
        vm.deal(alice, alice.balance + KFEE);
        vm.startPrank(alice);
        t.approve(address(lo), amt);
        id = lo.place{value: KFEE}(address(t), false, amt, minOut, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function _assertEmpty(HookTokenV2 t) internal view {
        assertEq(address(lo).balance, 0, "no AVAX left");
        assertEq(t.balanceOf(address(lo)), 0, "no tokens left");
        assertEq(t.allowance(address(lo), address(router)), 0, "router allowance reset");
    }

    function test_buyFillsOnlyAtTheLimit() public {
        HookTokenV2 t = _token();
        uint256 amt = 1 ether;
        uint256 net = amt - (amt * FEE) / 10_000;
        uint256 now_ = _quoteBuy(t, net);
        // Limit: 10% more tokens than the pool gives today, i.e. a 10% lower price.
        uint256 id = _placeBuy(t, amt, (now_ * 110) / 100);
        assertEq(address(lo).balance, amt + KFEE, "escrowed, with the keeper fee");

        vm.prank(keeper);
        vm.expectRevert();
        lo.fill(id);

        // Someone sells the price down: now the limit is reachable.
        deal(address(t), bob, 50_000_000 ether);
        _routerSell(bob, t, 50_000_000 ether);

        uint256 t0 = TREASURY.balance;
        vm.prank(keeper);
        uint256 out = lo.fill(id);
        assertEq(keeper.balance, KFEE, "the filler earns the keeper fee");
        assertGe(out, (now_ * 110) / 100, "at or above the limit");
        assertEq(t.balanceOf(alice), out, "tokens to the maker");
        assertEq(TREASURY.balance - t0, (amt * FEE) / 10_000, "fee in AVAX");
        assertEq(uint8(lo.getOrder(id).status), uint8(AvaxHookLimitOrders.Status.Filled));
        _assertEmpty(t);

        vm.prank(keeper);
        vm.expectRevert(AvaxHookLimitOrders.NotOpen.selector);
        lo.fill(id);
    }

    function test_sellFillsOnlyAtTheLimit() public {
        HookTokenV2 t = _token();
        uint256 bag = _routerBuy(alice, t, 2 ether);
        uint256 gross = _quoteSell(t, bag);
        uint256 limit = (gross * 120) / 100; // 20% above today's price
        uint256 id = _placeSell(t, bag, limit);
        assertEq(t.balanceOf(address(lo)), bag, "escrowed");

        vm.expectRevert(AvaxHookLimitOrders.Slippage.selector);
        lo.fill(id);
        assertEq(address(lo).balance, KFEE, "sells escrow only the keeper fee in AVAX");

        vm.deal(bob, 500 ether);
        _routerBuy(bob, t, 400 ether); // price pumps

        uint256 a0 = alice.balance;
        uint256 f0 = TREASURY.balance;
        vm.prank(keeper);
        uint256 out = lo.fill(id);
        assertEq(keeper.balance, KFEE, "the filler earns the keeper fee");
        assertGe(out, limit);
        assertEq(alice.balance - a0, out, "AVAX to the maker");
        uint256 fee = TREASURY.balance - f0;
        assertEq(fee, ((out + fee) * FEE) / 10_000, "fee from the gross output");
        _assertEmpty(t);
    }

    function test_cancelRefundsAndExpiredAnyoneReturns() public {
        HookTokenV2 t = _token();
        uint256 id = _placeBuy(t, 1 ether, type(uint128).max);

        vm.prank(bob);
        vm.expectRevert(AvaxHookLimitOrders.NotMaker.selector);
        lo.cancel(id);

        vm.prank(alice);
        lo.cancel(id);
        assertEq(alice.balance, 1 ether + KFEE, "refunded with the keeper fee");
        vm.expectRevert(AvaxHookLimitOrders.NotOpen.selector);
        lo.fill(id);

        uint256 bag = _routerBuy(alice, t, 1 ether);
        uint256 id2 = _placeSell(t, bag, type(uint128).max);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(AvaxHookLimitOrders.Expired.selector);
        lo.fill(id2);
        uint256 bob0 = bob.balance;
        vm.prank(bob); // anyone can return an expired order to its maker, and earns its keeper fee
        lo.cancel(id2);
        assertEq(t.balanceOf(alice), bag, "tokens back");
        assertEq(bob.balance - bob0, KFEE, "returner paid");
        assertEq(TREASURY.balance, 0, "no fee on cancels");
        _assertEmpty(t);
    }

    function test_refusesIdentityModulesAndCurveTokens() public {
        (HookTokenV2 pot,) = _one(nthPotId, _nthCfg(100, 5, 0.1 ether));
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(AvaxHookLimitOrders.NotOrderable.selector);
        lo.place{value: 1 ether + KFEE}(address(pot), true, 1 ether, 1, block.timestamp + 1);

        HookTokenV2 curve = _launch(_ids1(burnId), _cfgs1(_burnCfg(50)), 100);
        vm.prank(alice);
        vm.expectRevert(AvaxHookLimitOrders.NotOrderable.selector);
        lo.place{value: 1 ether + KFEE}(address(curve), true, 1 ether, 1, block.timestamp + 1);
    }

    function test_badInputsAndPause() public {
        HookTokenV2 t = _token();
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(AvaxHookLimitOrders.BadOrder.selector);
        lo.place{value: 1 ether}(address(t), true, 2 ether, 1, block.timestamp + 1); // value mismatch
        vm.expectRevert(AvaxHookLimitOrders.BadOrder.selector);
        lo.place{value: 1 ether}(address(t), true, 1 ether, 1, block.timestamp + 1); // keeper fee missing
        vm.expectRevert(AvaxHookLimitOrders.BadOrder.selector);
        lo.place{value: 1 ether + KFEE}(address(t), true, 1 ether, 0, block.timestamp + 1); // no limit
        vm.expectRevert(AvaxHookLimitOrders.BadOrder.selector);
        lo.place{value: 1 ether + KFEE}(address(t), true, 1 ether, 1, block.timestamp); // already expired
        vm.stopPrank();

        uint256 id = _placeBuy(t, 1 ether, 1);
        vm.prank(bob);
        vm.expectRevert();
        lo.setConfig(FEE, KFEE, TREASURY, true);
        vm.prank(SAFE);
        lo.setConfig(FEE, KFEE, TREASURY, true);
        vm.expectRevert(AvaxHookLimitOrders.Paused.selector);
        lo.fill(id);
        vm.prank(alice); // cancels still work while paused
        lo.cancel(id);

        vm.prank(SAFE);
        vm.expectRevert(AvaxHookLimitOrders.BadOrder.selector);
        lo.setConfig(101, KFEE, TREASURY, false); // fee cap 1%
        vm.prank(SAFE);
        vm.expectRevert(AvaxHookLimitOrders.BadOrder.selector);
        lo.setConfig(FEE, 0.1 ether + 1, TREASURY, false); // keeper fee cap
    }

    function test_feeIsFixedWhenPlaced() public {
        HookTokenV2 t = _token();
        uint256 id = _placeBuy(t, 1 ether, 1);
        vm.prank(SAFE);
        lo.setConfig(100, 0.01 ether, TREASURY, false);
        uint256 k0 = keeper.balance;
        vm.prank(keeper);
        lo.fill(id);
        assertEq(TREASURY.balance, (1 ether * FEE) / 10_000, "the order's own fee");
        assertEq(keeper.balance - k0, KFEE, "the order's own keeper fee");
    }

    function test_makerThatRefusesAvaxCanWithdraw() public {
        HookTokenV2 t = _token();
        NoReceive m = new NoReceive();
        vm.deal(address(this), 1 ether + KFEE);
        uint256 id = m.place{value: 1 ether + KFEE}(lo, address(t), type(uint128).max);
        m.cancel(lo, id);
        assertEq(lo.owed(address(m)), 1 ether + KFEE, "kept for withdraw");
        assertEq(address(lo).balance, 1 ether + KFEE);
    }

    function test_booksViews() public {
        HookTokenV2 t = _token();
        _placeBuy(t, 1 ether, 1);
        _placeBuy(t, 2 ether, 1);
        assertEq(lo.orderCount(), 2);
        assertEq(lo.orderIdsOf(alice).length, 2);
        AvaxHookLimitOrders.Order[] memory page = lo.getOrders(1, 10);
        assertEq(page.length, 1);
        assertEq(page[0].amountIn, 2 ether);
        assertEq(page[0].keeperFee, KFEE);
        assertEq(lo.getOrders(5, 10).length, 0);
    }
}
