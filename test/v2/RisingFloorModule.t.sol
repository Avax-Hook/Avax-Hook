// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {RisingFloorModule} from "../../contracts/v2/modules/RisingFloorModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract RisingFloorModuleTest is NewModulesBase {
    RisingFloorModule rf;
    uint32 rfId;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    function setUp() public override {
        super.setUp();
        rf = new RisingFloorModule(address(hook));
        rfId = modules.addModule(address(rf), '{"name":"Rising floor"}');
    }

    function _cfg(uint16 bps) internal pure returns (bytes memory) {
        return abi.encode(RisingFloorModule.Config(bps));
    }

    function _treasury(HookTokenV2 t) internal view returns (uint256 tr, uint256 circ) {
        (,, tr,,,, circ) = rf.stats(address(t));
    }

    function _redeem(address who, HookTokenV2 t, uint256 amt, uint256 minOut) internal returns (uint256 out) {
        vm.startPrank(who);
        t.approve(address(rf), amt);
        out = rf.redeem(address(t), amt, minOut);
        vm.stopPrank();
    }

    function test_configBoundsAndCaps() public {
        vm.expectRevert();
        rf.validateConfig(_cfg(0));
        vm.expectRevert();
        rf.validateConfig(_cfg(501));
        rf.validateConfig(_cfg(1));
        rf.validateConfig(_cfg(500));
        assertEq(rf.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        assertEq(rf.conflictGroups(), 0);
    }

    /// Curve buys and sells fill the treasury; redeeming waits for graduation (the token's transfer lock).
    function test_curveFillsTreasury_redeemAfterGraduationOnly() public {
        HookTokenV2 t = _launch(_one(rfId), _oneCfg(_cfg(100)), 0);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        rf.reconcile();
        (uint256 tr,) = _treasury(t);
        assertEq(tr, 0.1 ether, "1% of the buy");
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t), bal / 2, 0);
        rf.reconcile();
        (uint256 tr2,) = _treasury(t);
        assertGt(tr2, tr, "sell adds 1% of its output");
        assertEq(rf.accounted(address(0)), hook.claimable(address(rf), NATIVE), "books match the hook");

        vm.startPrank(alice);
        t.approve(address(rf), 1 ether);
        vm.expectRevert(RisingFloorModule.NotGraduated.selector);
        rf.redeem(address(t), 1 ether, 0);
        vm.stopPrank();
    }

    /// After graduation, a redemption pays amount × treasury / circulating and leaves the floor unchanged.
    function test_redeemKeepsFloor() public {
        (HookTokenV2 t, PoolKey memory key) = _launchOne(rfId, _cfg(200));
        uint256 got = _routerBuy(alice, t, 50 ether);
        _routerSell(alice, t, got / 4);
        agg.swap(key, true, -int256(5 ether)); // aggregator buys pay too
        rf.reconcile();
        (uint256 tr0, uint256 circ0) = _treasury(t);
        assertEq(circ0, SUPPLY - t.balanceOf(DEAD) - t.balanceOf(address(pad)));
        uint256 floor0 = rf.floorPrice(address(t));
        assertEq(floor0, (tr0 * 1e18) / circ0);

        uint256 amt = t.balanceOf(alice) / 2;
        uint256 q = rf.quoteRedeem(address(t), amt);
        assertEq(q, (amt * tr0) / circ0);
        uint256 b0 = alice.balance;
        uint256 dead0 = t.balanceOf(DEAD);
        uint256 out = _redeem(alice, t, amt, q);
        assertEq(out, q);
        assertEq(alice.balance - b0, out, "paid in AVAX");
        assertEq(t.balanceOf(DEAD) - dead0, amt, "burned");
        (uint256 tr1, uint256 circ1) = _treasury(t);
        assertEq(tr1, tr0 - out);
        assertEq(circ1, circ0 - amt);
        assertGe(rf.floorPrice(address(t)), floor0, "floor never falls");
        assertApproxEqRel(rf.floorPrice(address(t)), floor0, 1e6, "floor unchanged");
        // solvency: cash held + claim in the hook cover the treasury
        assertGe(address(rf).balance + hook.claimable(address(rf), NATIVE), tr1);
        assertEq(address(rf).balance, rf.cash(address(0)));
    }

    function test_tradesRaiseFloor() public {
        (HookTokenV2 t,) = _launchOne(rfId, _cfg(100));
        rf.reconcile();
        uint256 f0 = rf.floorPrice(address(t));
        uint256 got = _routerBuy(alice, t, 10 ether);
        rf.reconcile();
        uint256 f1 = rf.floorPrice(address(t));
        assertGt(f1, f0, "buy fee");
        _routerSell(alice, t, got);
        rf.reconcile();
        assertGt(rf.floorPrice(address(t)), f1, "sell fee");
    }

    function test_redeemRefusals() public {
        (HookTokenV2 t,) = _launchOne(rfId, _cfg(100));
        address h = _holder(0);
        uint256 bal = t.balanceOf(h);
        vm.startPrank(h);
        vm.expectRevert(RisingFloorModule.ZeroAmount.selector);
        rf.redeem(address(t), 0, 0);
        vm.expectRevert(); // no allowance
        rf.redeem(address(t), bal, 0);
        t.approve(address(rf), bal);
        uint256 q = rf.quoteRedeem(address(t), bal);
        vm.expectRevert(abi.encodeWithSelector(RisingFloorModule.Slippage.selector, q));
        rf.redeem(address(t), bal, q + 1);
        vm.expectRevert(); // more than the balance
        rf.redeem(address(t), bal + 1, 0);
        vm.expectRevert(RisingFloorModule.UnknownToken.selector);
        rf.redeem(address(0xBEEF), 1, 0);
        vm.stopPrank();
    }

    /// ERC-20 quote: the module withdraws its USDC claim from the hook and pays it.
    function test_erc20Quote() public {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Floor";
        a.symbol = "FLR";
        a.quote = USDC;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(rfId);
        a.moduleConfigs = _oneCfg(_cfg(300));
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        HookTokenV2 t = HookTokenV2(pad.launch{value: fee}(a));
        uint256 target = uint256(pad.getLaunch(address(t)).target);
        deal(USDC, alice, target * 3);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(pad), type(uint256).max);
        pad.buyWithQuote(address(t), target * 2, 0);
        vm.stopPrank();
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        rf.reconcile();
        (uint256 tr, uint256 circ) = _treasury(t);
        assertGt(tr, 0);
        uint256 amt = t.balanceOf(alice) / 3;
        uint256 b0 = IERC20(USDC).balanceOf(alice);
        uint256 out = _redeem(alice, t, amt, 1);
        assertEq(out, (amt * tr) / circ);
        assertEq(IERC20(USDC).balanceOf(alice) - b0, out, "paid in USDC");
        assertEq(IERC20(USDC).balanceOf(address(rf)), rf.cash(USDC));
        assertGe(rf.cash(USDC) + hook.claimable(address(rf), Currency.wrap(USDC)), tr - out);
    }

    /// Disabling the module stops fees but the treasury stays redeemable; rescue moves nothing.
    function test_killSwitchKeepsTreasury() public {
        (HookTokenV2 t,) = _launchOne(rfId, _cfg(100));
        modules.disable(rfId);
        rf.rescue(address(t));
        rf.reconcile();
        (uint256 tr,) = _treasury(t);
        assertGt(tr, 0);
        address h = _holder(1);
        uint256 out = _redeem(h, t, t.balanceOf(h), 1);
        assertGt(out, 0);
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_redeemNeverLowersFloor(uint256 seed, uint256 frac) public {
        (HookTokenV2 t,) = _launchOne(rfId, _cfg(uint16(bound(seed, 1, 500))));
        _routerBuy(alice, t, bound(seed >> 16, 1 ether, 200 ether));
        rf.reconcile();
        uint256 f0 = rf.floorPrice(address(t));
        uint256 bal = t.balanceOf(alice);
        uint256 amt = bound(frac, 1e9, bal);
        if (rf.quoteRedeem(address(t), amt) == 0) return;
        _redeem(alice, t, amt, 0);
        assertGe(rf.floorPrice(address(t)), f0);
        address h = _holder(2);
        _redeem(h, t, t.balanceOf(h), 0);
        assertGe(rf.floorPrice(address(t)), f0);
    }
}
