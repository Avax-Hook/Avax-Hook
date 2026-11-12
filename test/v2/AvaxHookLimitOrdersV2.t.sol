// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {AvaxHookLimitOrders} from "../../contracts/v2/AvaxHookLimitOrders.sol";
import {AvaxHookZap} from "../../contracts/v2/AvaxHookZap.sol";
import {AvaxHookLimitOrdersV2} from "../../contracts/v2/AvaxHookLimitOrdersV2.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

/// Refuses AVAX, like a maker contract without `receive`.
contract NoReceiveV2 {
    function place(AvaxHookLimitOrdersV2 lo, address token, uint256 minOut) external payable returns (uint256) {
        return lo.place{value: msg.value}(token, true, msg.value - lo.keeperFee(), minOut, block.timestamp + 1 days);
    }

    function cancel(AvaxHookLimitOrdersV2 lo, uint256 id) external {
        lo.cancel(id);
    }
}

/// Stands in for the router on a sell that the pool only partly fills (price limit reached):
/// takes half the tokens and pays 1 AVAX.
contract HalfFillRouter {
    function sell(address token, uint256 amountIn, uint256, uint256, bytes calldata) external returns (uint256) {
        IERC20(token).transferFrom(msg.sender, address(this), amountIn / 2);
        (bool ok,) = msg.sender.call{value: 1 ether}("");
        require(ok);
        return 1 ether;
    }
}

/// Circle's FiatToken (USDC on Avalanche): the real blacklist, driven through its blacklister on the fork.
interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
}

contract AvaxHookLimitOrdersV2Test is V1PortBase {
    address constant TREASURY = address(0x7EA5);
    uint16 constant FEE = 10; // 0.1%
    uint88 constant KFEE = 0.003 ether;

    AvaxHookZap zap;
    AvaxHookLimitOrdersV2 lo;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        address[] memory neutral = new address[](2);
        (neutral[0], neutral[1]) = (address(burn), address(antiSnipe));
        zap = new AvaxHookZap(router, neutral, SAFE);
        lo = new AvaxHookLimitOrdersV2(zap, FEE, KFEE, TREASURY, SAFE);
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
        assertEq(uint8(lo.getOrder(id).status), uint8(AvaxHookLimitOrdersV2.Status.Filled));
        _assertEmpty(t);

        vm.prank(keeper);
        vm.expectRevert(AvaxHookLimitOrdersV2.NotOpen.selector);
        lo.fill(id);
    }

    function test_sellFillsOnlyAtTheLimit() public {
        HookTokenV2 t = _token();
        uint256 bag = _routerBuy(alice, t, 2 ether);
        uint256 gross = _quoteSell(t, bag);
        uint256 limit = (gross * 120) / 100; // 20% above today's price
        uint256 id = _placeSell(t, bag, limit);
        assertEq(t.balanceOf(address(lo)), bag, "escrowed");

        vm.expectRevert(AvaxHookLimitOrdersV2.Slippage.selector);
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

    function test_partialSellFillRefundsUnsoldTokens() public {
        HookTokenV2 t = _token();
        uint256 bag = _routerBuy(alice, t, 2 ether);
        uint256 id = _placeSell(t, bag, 0.5 ether);
        uint256 held = t.balanceOf(alice);

        vm.etch(address(router), address(new HalfFillRouter()).code);
        vm.deal(address(router), 1 ether);
        vm.prank(keeper);
        uint256 out = lo.fill(id);
        assertEq(out, 1 ether - (1 ether * FEE) / 10_000);
        assertEq(t.balanceOf(alice) - held, bag - bag / 2, "unsold tokens back to the maker");
        assertEq(t.balanceOf(address(lo)), 0, "nothing left for sweep");
        assertEq(lo.sweepable(address(t)), 0);
    }

    function test_cancelRefundsAndExpiredAnyoneReturns() public {
        HookTokenV2 t = _token();
        uint256 id = _placeBuy(t, 1 ether, type(uint128).max);

        vm.prank(bob);
        vm.expectRevert(AvaxHookLimitOrdersV2.NotMaker.selector);
        lo.cancel(id);

        vm.prank(alice);
        lo.cancel(id);
        assertEq(alice.balance, 1 ether + KFEE, "refunded with the keeper fee");
        vm.expectRevert(AvaxHookLimitOrdersV2.NotOpen.selector);
        lo.fill(id);

        uint256 bag = _routerBuy(alice, t, 1 ether);
        uint256 id2 = _placeSell(t, bag, type(uint128).max);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(AvaxHookLimitOrdersV2.Expired.selector);
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
        vm.expectRevert(AvaxHookLimitOrdersV2.NotOrderable.selector);
        lo.place{value: 1 ether + KFEE}(address(pot), true, 1 ether, 1, block.timestamp + 1);

        HookTokenV2 curve = _launch(_ids1(burnId), _cfgs1(_burnCfg(50)), 100);
        vm.prank(alice);
        vm.expectRevert(AvaxHookLimitOrdersV2.NotOrderable.selector);
        lo.place{value: 1 ether + KFEE}(address(curve), true, 1 ether, 1, block.timestamp + 1);
    }

    function test_badInputsAndPause() public {
        HookTokenV2 t = _token();
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(AvaxHookLimitOrdersV2.BadOrder.selector);
        lo.place{value: 1 ether}(address(t), true, 2 ether, 1, block.timestamp + 1); // value mismatch
        vm.expectRevert(AvaxHookLimitOrdersV2.BadOrder.selector);
        lo.place{value: 1 ether}(address(t), true, 1 ether, 1, block.timestamp + 1); // keeper fee missing
        vm.expectRevert(AvaxHookLimitOrdersV2.BadOrder.selector);
        lo.place{value: 1 ether + KFEE}(address(t), true, 1 ether, 0, block.timestamp + 1); // no limit
        vm.expectRevert(AvaxHookLimitOrdersV2.BadOrder.selector);
        lo.place{value: 1 ether + KFEE}(address(t), true, 1 ether, 1, block.timestamp); // already expired
        vm.stopPrank();

        uint256 id = _placeBuy(t, 1 ether, 1);
        vm.prank(bob);
        vm.expectRevert();
        lo.setConfig(FEE, KFEE, TREASURY, true);
        vm.prank(SAFE);
        lo.setConfig(FEE, KFEE, TREASURY, true);
        vm.expectRevert(AvaxHookLimitOrdersV2.Paused.selector);
        lo.fill(id);
        vm.prank(alice); // cancels still work while paused
        lo.cancel(id);

        vm.prank(SAFE);
        vm.expectRevert(AvaxHookLimitOrdersV2.BadOrder.selector);
        lo.setConfig(101, KFEE, TREASURY, false); // fee cap 1%
        vm.prank(SAFE);
        vm.expectRevert(AvaxHookLimitOrdersV2.BadOrder.selector);
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
        NoReceiveV2 m = new NoReceiveV2();
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
        AvaxHookLimitOrdersV2.Order[] memory page = lo.getOrders(1, 10);
        assertEq(page.length, 1);
        assertEq(page[0].amountIn, 2 ether);
        assertEq(page[0].keeperFee, KFEE);
        assertEq(lo.getOrders(5, 10).length, 0);
    }

    // ---------------------------------------------------------------- V2: blacklisted makers, sweep

    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    /// A graduated USDC-quote token (Auto-burn, zappable), and `alice` funded with USDC.
    function _usdcToken() internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Usd";
        a.symbol = "USD";
        a.quote = USDC;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _ids1(burnId);
        a.moduleConfigs = _cfgs1(_burnCfg(50));
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookTokenV2(pad.launch{value: fee}(a));
        uint256 target = uint256(pad.getLaunch(address(t)).target);
        vm.roll(vm.getBlockNumber() + CURVE_WINDOWS);
        deal(USDC, bob, target * 3);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(pad), type(uint256).max);
        pad.buyWithQuote(address(t), target * 2, 0);
        vm.stopPrank();
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        deal(USDC, alice, 1_000e6);
    }

    function _blacklist(address who) internal {
        IFiatToken usdc = IFiatToken(USDC);
        vm.prank(usdc.blacklister());
        usdc.blacklist(who);
        assertTrue(usdc.isBlacklisted(who));
    }

    function _placeUsdcBuy(HookTokenV2 t, uint256 amt, uint256 minOut) internal returns (uint256 id) {
        vm.deal(alice, alice.balance + KFEE);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(lo), amt);
        id = lo.place{value: KFEE}(address(t), true, amt, minOut, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_blacklistedMakerCancelCreditsAndWithdrawsElsewhere() public {
        HookTokenV2 t = _usdcToken();
        uint256 id = _placeUsdcBuy(t, 100e6, type(uint128).max);
        assertEq(lo.escrowed(USDC), 100e6);
        _blacklist(alice);

        uint256 a0 = alice.balance;
        vm.prank(alice);
        lo.cancel(id); // v1 reverts here: safeTransfer to a blacklisted maker
        assertEq(uint8(lo.getOrder(id).status), uint8(AvaxHookLimitOrdersV2.Status.Cancelled), "left Open");
        assertEq(lo.owedToken(alice, USDC), 100e6, "credited");
        assertEq(lo.owedTotal(USDC), 100e6);
        assertEq(lo.escrowed(USDC), 0);
        assertEq(alice.balance - a0, KFEE, "keeper fee back in AVAX");

        vm.prank(alice);
        vm.expectRevert(); // to herself: still blacklisted
        lo.withdrawToken(USDC, alice);

        vm.prank(alice);
        assertEq(lo.withdrawToken(USDC, carol), 100e6);
        assertEq(IERC20(USDC).balanceOf(carol), 100e6, "pulled to another address");
        assertEq(lo.owedToken(alice, USDC), 0);
        assertEq(lo.owedTotal(USDC), 0);
        assertEq(IERC20(USDC).balanceOf(address(lo)), 0);

        vm.prank(alice);
        vm.expectRevert(AvaxHookLimitOrdersV2.NothingOwed.selector);
        lo.withdrawToken(USDC, carol);
    }

    /// The same flow on the live v1 code: the order can never leave Open.
    function test_v1_blacklistedMakerIsStuck() public {
        AvaxHookLimitOrders v1 = new AvaxHookLimitOrders(zap, FEE, KFEE, TREASURY, SAFE);
        HookTokenV2 t = _usdcToken();
        vm.deal(alice, alice.balance + KFEE);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(v1), 100e6);
        uint256 id = v1.place{value: KFEE}(address(t), true, 100e6, type(uint128).max, block.timestamp + 1 days);
        vm.stopPrank();
        _blacklist(alice);
        vm.prank(alice);
        vm.expectRevert();
        v1.cancel(id);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        vm.expectRevert();
        v1.cancel(id);
    }

    function test_expiredBlacklistedOrderReturnedByThirdParty() public {
        HookTokenV2 t = _usdcToken();
        uint256 id = _placeUsdcBuy(t, 50e6, type(uint128).max);
        _blacklist(alice);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        lo.cancel(id);
        assertEq(bob.balance - b0, KFEE, "returner earns the keeper fee");
        assertEq(lo.owedToken(alice, USDC), 50e6, "maker credited");
        assertEq(lo.escrowed(USDC), 0);
        assertEq(lo.escrowed(address(0)), 0);
    }

    function test_blacklistedMakerSellFillCredited() public {
        HookTokenV2 t = _usdcToken();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), 200e6);
        uint256 bag = router.buy(address(t), 200e6, 0, address(0), block.timestamp, "");
        t.approve(address(lo), bag);
        vm.deal(alice, alice.balance + KFEE);
        uint256 id = lo.place{value: KFEE}(address(t), false, bag, 1, block.timestamp + 1 days);
        vm.stopPrank();
        _blacklist(alice);

        uint256 f0 = IERC20(USDC).balanceOf(TREASURY);
        vm.prank(keeper);
        uint256 out = lo.fill(id);
        assertGt(out, 0);
        assertEq(lo.owedToken(alice, USDC), out, "fill output credited, fill not blocked");
        assertGt(IERC20(USDC).balanceOf(TREASURY) - f0, 0, "fee still paid");
        assertEq(keeper.balance, KFEE);
        assertEq(IERC20(USDC).balanceOf(address(lo)), out, "only the credit stays");
        assertEq(lo.sweepable(USDC), 0, "a credit is not sweepable");
        vm.prank(alice);
        lo.withdrawToken(USDC, carol);
        assertEq(IERC20(USDC).balanceOf(carol), out);
    }

    function test_nativeOwedWithdrawTokenToAnotherAddress() public {
        HookTokenV2 t = _token();
        NoReceiveV2 m = new NoReceiveV2();
        vm.deal(address(this), 1 ether + KFEE);
        uint256 id = m.place{value: 1 ether + KFEE}(lo, address(t), type(uint128).max);
        m.cancel(lo, id);
        assertEq(lo.owedTotal(address(0)), 1 ether + KFEE);
        vm.prank(address(m));
        lo.withdrawToken(address(0), carol);
        assertEq(carol.balance, 100_000 ether + 1 ether + KFEE);
        assertEq(lo.owed(address(m)), 0);
        assertEq(lo.owedTotal(address(0)), 0);
    }

    function test_sweepCannotTouchEscrowOrCredits() public {
        HookTokenV2 t = _usdcToken();
        HookTokenV2 a = _token();
        uint256 idU = _placeUsdcBuy(t, 100e6, type(uint128).max); // USDC escrow + AVAX keeper fee
        uint256 idA = _placeBuy(a, 1 ether, type(uint128).max); // AVAX escrow
        vm.deal(alice, 10 ether);
        uint256 bag = _routerBuy(alice, a, 1 ether);
        uint256 idS = _placeSell(a, bag, type(uint128).max); // token escrow
        // A credited payout: a second maker, blacklisted, cancels.
        deal(USDC, carol, 10e6);
        vm.deal(carol, carol.balance + KFEE);
        vm.startPrank(carol);
        IERC20(USDC).approve(address(lo), 10e6);
        uint256 idC = lo.place{value: KFEE}(address(t), true, 10e6, type(uint128).max, block.timestamp + 1 days);
        vm.stopPrank();
        _blacklist(carol);
        vm.prank(carol);
        lo.cancel(idC);
        assertEq(lo.owedToken(carol, USDC), 10e6);

        assertEq(lo.sweepable(USDC), 0);
        assertEq(lo.sweepable(address(0)), 0);
        assertEq(lo.sweepable(address(a)), 0);

        vm.startPrank(SAFE);
        vm.expectRevert(AvaxHookLimitOrdersV2.Reserved.selector);
        lo.sweep(USDC, SAFE, 1);
        vm.expectRevert(AvaxHookLimitOrdersV2.Reserved.selector);
        lo.sweep(address(0), SAFE, 1);
        vm.expectRevert(AvaxHookLimitOrdersV2.Reserved.selector);
        lo.sweep(address(a), SAFE, 1);
        vm.stopPrank();

        // Strays: sent here outside any order.
        deal(USDC, bob, 7e6);
        vm.prank(bob);
        IERC20(USDC).transfer(address(lo), 7e6);
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(lo).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(lo.sweepable(USDC), 7e6);
        assertEq(lo.sweepable(address(0)), 2 ether);

        vm.prank(bob);
        vm.expectRevert();
        lo.sweep(USDC, bob, 7e6); // owner only

        address to = makeAddr("sweepTo");
        vm.startPrank(SAFE);
        vm.expectRevert(AvaxHookLimitOrdersV2.Reserved.selector);
        lo.sweep(USDC, to, 7e6 + 1);
        lo.sweep(USDC, to, 7e6);
        lo.sweep(address(0), to, 2 ether);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(to), 7e6);
        assertEq(to.balance, 2 ether);

        // Every maker still gets everything back.
        vm.startPrank(alice);
        lo.cancel(idU);
        lo.cancel(idA);
        lo.cancel(idS);
        vm.stopPrank();
        vm.prank(carol);
        lo.withdrawToken(USDC, bob);
        assertEq(IERC20(USDC).balanceOf(address(lo)), 0);
        assertEq(address(lo).balance, 0);
        assertEq(a.balanceOf(address(lo)), 0);
        assertEq(lo.escrowed(USDC) + lo.escrowed(address(0)) + lo.escrowed(address(a)), 0);
    }
}
