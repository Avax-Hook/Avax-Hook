// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookZap} from "../../contracts/v2/AvaxHookZap.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

/// Stands in for Augustus v6.2: takes `spend` of src (value for AVAX, pulled with transferFrom for ERC-20s, as
/// v6.2 does itself) and pays `out` of dst to `recv`. `fail` makes the call revert.
contract MockAugustus {
    fallback() external payable {
        (address src, uint256 spend, address dst, uint256 out, address recv, bool fail) =
            abi.decode(msg.data, (address, uint256, address, uint256, address, bool));
        require(!fail, "route failed");
        if (src == address(0)) require(msg.value == spend, "value");
        else IERC20(src).transferFrom(msg.sender, address(this), spend);
        if (dst == address(0)) {
            (bool ok,) = recv.call{value: out}("");
            require(ok, "pay");
        } else {
            IERC20(dst).transfer(recv, out);
        }
    }
}

contract AvaxHookZapTest is V1PortBase {
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    /// v6.2 has no separate proxy: approvals go to Augustus.
    address constant PROXY = AUGUSTUS;

    AvaxHookZap zap;

    function setUp() public override {
        super.setUp();
        vm.etch(AUGUSTUS, address(new MockAugustus()).code);
        vm.deal(AUGUSTUS, 10_000 ether);
        deal(USDC, AUGUSTUS, 10_000_000e6);
        address[] memory neutral = new address[](10);
        (neutral[0], neutral[1], neutral[2], neutral[3], neutral[4]) =
            (address(antiSnipe), address(whale), address(dump), address(mev), address(sellTax));
        (neutral[5], neutral[6], neutral[7], neutral[8], neutral[9]) =
            (address(surge), address(vol), address(burn), address(buyback), address(lpRewards));
        zap = new AvaxHookZap(router, neutral, SAFE);
    }

    function _route(address src, uint256 spend, address dst, uint256 out, bool fail) internal view returns (bytes memory) {
        return abi.encode(src, spend, dst, out, address(zap), fail);
    }

    function _buyArgs(HookTokenV2 t, uint256 usdcIn, uint256 avaxOut, uint256 minQuote) internal view returns (AvaxHookZap.Buy memory) {
        return AvaxHookZap.Buy({
            token: address(t),
            src: USDC,
            srcAmount: usdcIn,
            swapData: _route(USDC, usdcIn, address(0), avaxOut, false),
            minQuote: minQuote,
            minTokensOut: 1,
            deadline: block.timestamp + 600
        });
    }

    function _assertEmpty(HookTokenV2 t) internal view {
        assertEq(address(zap).balance, 0, "no AVAX left");
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0, "no USDC left");
        assertEq(t.balanceOf(address(zap)), 0, "no tokens left");
        assertEq(IERC20(USDC).allowance(address(zap), PROXY), 0, "proxy allowance reset");
        assertEq(t.allowance(address(zap), address(router)), 0, "router allowance reset");
    }

    function test_buyWithUsdcInOneCall() public {
        (HookTokenV2 t,) = _one(burnId, _burnCfg(50));
        deal(USDC, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zap), 100e6);
        uint256 out = zap.buy(_buyArgs(t, 100e6, 9 ether, 9 ether));
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(t.balanceOf(alice), out, "tokens to the caller");
        assertEq(IERC20(USDC).balanceOf(alice), 0);
        _assertEmpty(t);
    }

    function test_unspentSourceIsRefunded() public {
        (HookTokenV2 t,) = _one(burnId, _burnCfg(50));
        deal(USDC, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zap), 100e6);
        AvaxHookZap.Buy memory a = _buyArgs(t, 100e6, 9 ether, 9 ether);
        a.swapData = _route(USDC, 60e6, address(0), 9 ether, false); // the route spends only 60 USDC
        zap.buy(a);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(alice), 40e6, "unspent USDC back");
        _assertEmpty(t);
    }

    function test_sellForUsdcInOneCall() public {
        (HookTokenV2 t,) = _one(burnId, _burnCfg(50));
        uint256 got = _routerBuy(alice, t, 5 ether);
        vm.startPrank(alice);
        t.approve(address(zap), got);
        uint256 aggIn = 3 ether; // the pool pays more than this: the rest comes back as AVAX
        uint256 avax0 = alice.balance;
        uint256 out = zap.sell(
            AvaxHookZap.Sell({
                token: address(t),
                amount: got,
                minQuote: aggIn,
                dest: USDC,
                aggIn: aggIn,
                swapData: _route(address(0), aggIn, USDC, 30e6, false),
                minDestOut: 30e6,
                deadline: block.timestamp + 600
            })
        );
        vm.stopPrank();
        assertEq(out, 30e6);
        assertEq(IERC20(USDC).balanceOf(alice), 30e6, "USDC to the caller");
        assertGt(alice.balance, avax0, "the quote beyond aggIn comes back");
        assertEq(t.balanceOf(alice), 0);
        _assertEmpty(t);
    }

    function test_refusesIdentityModules() public {
        (HookTokenV2 t,) = _one(nthPotId, _nthCfg(100, 5, 0.1 ether));
        deal(USDC, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(AvaxHookZap.IdentityModule.selector, address(nthPot)));
        zap.buy(_buyArgs(t, 100e6, 9 ether, 9 ether));
        vm.stopPrank();
    }

    function test_refusesBeforeGraduation() public {
        HookTokenV2 t = _launch(_ids1(burnId), _cfgs1(_burnCfg(50)), 100);
        deal(USDC, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zap), 100e6);
        vm.expectRevert(AvaxHookZap.NotGraduated.selector);
        zap.buy(_buyArgs(t, 100e6, 9 ether, 9 ether));
        vm.stopPrank();
    }

    function test_failedRouteAndSlippageRevert() public {
        (HookTokenV2 t,) = _one(burnId, _burnCfg(50));
        deal(USDC, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zap), 100e6);
        AvaxHookZap.Buy memory a = _buyArgs(t, 100e6, 9 ether, 9 ether);
        a.swapData = _route(USDC, 100e6, address(0), 9 ether, true);
        vm.expectRevert(AvaxHookZap.AggregatorFailed.selector);
        zap.buy(a);
        a = _buyArgs(t, 100e6, 8 ether, 9 ether); // delivers less than minQuote
        vm.expectRevert(AvaxHookZap.Slippage.selector);
        zap.buy(a);
        a = _buyArgs(t, 100e6, 9 ether, 9 ether);
        a.minTokensOut = type(uint256).max;
        vm.expectRevert(); // the router's own slippage check
        zap.buy(a);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(alice), 100e6, "nothing taken");
    }

    function test_badInputs() public {
        (HookTokenV2 t,) = _one(burnId, _burnCfg(50));
        AvaxHookZap.Buy memory a = _buyArgs(t, 1 ether, 1 ether, 1 ether);
        a.src = address(0); // the pool's quote: use the router directly
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AvaxHookZap.SameAsQuote.selector);
        zap.buy{value: 1 ether}(a);
        a = _buyArgs(t, 100e6, 9 ether, 9 ether);
        vm.prank(alice);
        vm.expectRevert(AvaxHookZap.BadValue.selector);
        zap.buy{value: 1}(a); // value with an ERC-20 source
        a.deadline = block.timestamp - 1;
        vm.prank(alice);
        vm.expectRevert(AvaxHookZap.Expired.selector);
        zap.buy(a);
    }

    /// The zap only ever spends the caller's own funds: another wallet's approval can't be pulled.
    function test_cantSpendSomeoneElsesApproval() public {
        (HookTokenV2 t,) = _one(burnId, _burnCfg(50));
        deal(USDC, bob, 100e6);
        vm.prank(bob);
        IERC20(USDC).approve(address(zap), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(); // alice has no USDC: transferFrom(alice) fails
        zap.buy(_buyArgs(t, 100e6, 9 ether, 9 ether));
        assertEq(IERC20(USDC).balanceOf(bob), 100e6);
    }

    function test_onlyOwnerSetsNeutral() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        zap.setNeutral(address(nthPot), true);
        vm.prank(SAFE);
        zap.setNeutral(address(nthPot), true);
        assertTrue(zap.neutral(address(nthPot)));
    }

    /// The app asks first: neutral pools are zappable, others name their blocking module, curves aren't yet.
    function test_zappableView() public {
        (HookTokenV2 ok,) = _one(burnId, _burnCfg(50));
        (bool z, address blocker) = zap.zappable(address(ok));
        assertTrue(z);
        assertEq(blocker, address(0));
        (HookTokenV2 pot,) = _one(nthPotId, _nthCfg(100, 5, 0.1 ether));
        (z, blocker) = zap.zappable(address(pot));
        assertFalse(z);
        assertEq(blocker, address(nthPot));
        HookTokenV2 curve = _launch(_ids1(burnId), _cfgs1(_burnCfg(50)), 100);
        (z, blocker) = zap.zappable(address(curve));
        assertFalse(z);
        assertEq(blocker, address(0));
    }

    function test_keyLookup() public {
        (, PoolKey memory key) = _one(burnId, _burnCfg(50));
        assertEq(address(key.hooks), address(hook));
    }
}
