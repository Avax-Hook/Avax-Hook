// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookLaunchpad} from "../../../contracts/HookLaunchpad.sol";
import {StockOrders} from "../../../contracts/stock/StockOrders.sol";
import {StockOrdersTest} from "../../StockOrders.t.sol";

/// PoC: a post-graduation BuyLaunch fill swaps through AvaxHookRouter with payer = StockOrders, so the
/// hook books the Nth-buy pot (and last-buyer pot leadership) to StockOrders, which has no way to call
/// AvaxHook.claim. The user whose order triggered the win gets nothing; the pot is stuck forever.
/// Regression: `claimHookCredits` lets the owner forward those credits.
contract StockOrdersPotPoc is StockOrdersTest {
    function test_potWonByStockOrders_ownerForwardsIt() public {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Pot";
        a.symbol = "POT";
        a.quote = address(mNVDA);
        a.hook.baseFeePips = 3_000;
        a.hook.maxFeePips = 3_000;
        a.hook.potBps = 500; // 5% of each buy into the Nth-buy pot
        a.hook.potEveryNBuys = 2;
        a.hook.potMinBuy = 1;
        uint256 fee = pad.creationFee();
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        address t = pad.launch{value: fee}(a);
        _mintStock(carol, 200 ether);
        vm.startPrank(carol);
        mNVDA.approve(address(pad), type(uint256).max);
        pad.buyWithQuote(t, 60 ether, 0);
        assertTrue(pad.getLaunch(t).graduated);
        // buy #1 through the router (fills the pot, doesn't win)
        mNVDA.approve(address(router), type(uint256).max);
        router.buy(t, 10 ether, 0, address(0), block.timestamp);
        vm.stopPrank();

        // buy #2: alice's BuyLaunch order filled by the solver, next block
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 2_000e6, address(mNVDA), t, 1, _dl(), alice);
        vm.prank(solver);
        orders.fill(id, 9 ether);

        uint256 stuck = hook.claimable(address(orders), Currency.wrap(address(mNVDA)));
        emit log_named_uint("pot credited to StockOrders (unclaimable)", stuck);
        assertGt(stuck, 0.9 ether); // ~5% of both buys
        assertEq(hook.claimable(alice, Currency.wrap(address(mNVDA))), 0);

        // fix: the owner forwards the credit to the user whose fill won it
        vm.expectRevert();
        vm.prank(alice);
        orders.claimHookCredits(Currency.wrap(address(mNVDA)), alice);
        uint256 aliceBefore = mNVDA.balanceOf(alice);
        vm.prank(owner);
        assertEq(orders.claimHookCredits(Currency.wrap(address(mNVDA)), alice), stuck);
        assertEq(mNVDA.balanceOf(alice) - aliceBefore, stuck);
        assertEq(hook.claimable(address(orders), Currency.wrap(address(mNVDA))), 0);
    }
}
