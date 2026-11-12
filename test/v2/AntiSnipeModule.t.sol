// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HookModuleBase} from "../../contracts/v2/modules/HookModuleBase.sol";
import {AntiSnipeModule} from "../../contracts/v2/modules/AntiSnipeModule.sol";
import {NthBuyPotModule} from "../../contracts/v2/modules/NthBuyPotModule.sol";
import {V1PortBase} from "./V1PortBase.t.sol";
import {RoundTripper} from "./AntiBundleModule.t.sol";

/// A registered module that tries to inflate a pot without crediting it.
contract FakeFunder is HookModuleBase {
    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata) public pure override {}

    function onRegister(PoolId, address, address, address, bytes calldata) external override onlyHook {}

    function cheat(NthBuyPotModule pot, PoolId id, uint256 amount) external {
        pot.addSnipeTax(id, amount);
    }
}

contract AntiSnipeModuleTest is V1PortBase {
    function _guarded() internal returns (HookTokenV2 t, PoolKey memory key) {
        (t, key) = _one(antiSnipeId, _antiSnipeCfg(150, 5 ether, 1_500));
    }

    // v1 test_graduationIntoUniswapV4 (guard part): per-block cap, snipe tax, window end.
    function test_perBlockCapAndSnipeTaxToProtocol() public {
        (HookTokenV2 t, PoolKey memory key) = _guarded();
        PoolId id = _id(key);
        assertTrue(antiSnipe.guardActive(id));
        vm.expectRevert(); // over the per-block cap
        _routerBuy(bob, t, 6 ether);

        address prot = hook.PROTOCOL();
        uint256 p0 = hook.claimable(prot, NATIVE);
        _routerBuy(bob, t, 3 ether);
        // core 0.3% + 15% snipe tax (no pot in the pool: protocol)
        assertEq(hook.claimable(prot, NATIVE) - p0, 0.009 ether + 0.45 ether);
        vm.expectRevert(); // wrapped by the PoolManager
        _routerBuy(carol, t, 2.5 ether); // the cap is shared by every buyer in the block
        _routerBuy(carol, t, 2 ether);

        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(carol, t, 5 ether); // a new block, a new cap
        assertEq(hook.claimable(prot, NATIVE) - p0, 0.03 ether + 0.45 ether + 0.3 ether + 0.75 ether);

        vm.roll(vm.getBlockNumber() + 150);
        assertFalse(antiSnipe.guardActive(id));
        uint256 p1 = hook.claimable(prot, NATIVE);
        _routerBuy(carol, t, 20 ether); // window over: no cap, no tax
        assertEq(hook.claimable(prot, NATIVE) - p1, 0.06 ether);
    }

    function test_sellsUntouchedDuringGuard() public {
        (HookTokenV2 t,) = _guarded();
        uint256 got = _routerBuy(bob, t, 4 ether);
        uint256 out = _routerSell(bob, t, got);
        assertGt(out, 3 ether); // only core + LP fees on the way out
    }

    function test_snipeTaxFundsNthPot_bothOrders() public {
        for (uint256 o; o < 2; ++o) {
            uint32[] memory ids = o == 0 ? _ids2(antiSnipeId, nthPotId) : _ids2(nthPotId, antiSnipeId);
            bytes memory a = _antiSnipeCfg(150, 0, 1_000);
            bytes memory n = _nthCfg(100, 25, 0.1 ether);
            (HookTokenV2 t, PoolKey memory key) = _many(ids, o == 0 ? _cfgs2(a, n) : _cfgs2(n, a), 100);
            PoolId id = _id(key);
            uint256 pot0 = nthPot.potOf(id).pot; // curve buys' shares (anti-snipe is pool-only)
            _routerBuy(bob, t, 1 ether);
            // 10% snipe tax + 1% pot share, all held by the pot module as its claim
            assertEq(nthPot.potOf(id).pot - pot0, 0.11 ether);
            assertEq(antiSnipe.guardOf(id).sink, address(nthPot));
            nthPot.reconcile(); // the hook really booked it
            assertEq(nthPot.potOf(id).pot - pot0, 0.11 ether);
        }
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
    }

    function test_snipeTaxPrefersNthPotThenTimerPot() public {
        uint32[] memory ids = new uint32[](3);
        bytes[] memory cfgs = new bytes[](3);
        (ids[0], ids[1], ids[2]) = (antiSnipeId, timerPotId, nthPotId);
        cfgs[0] = _antiSnipeCfg(150, 0, 1_000);
        cfgs[1] = _timerCfg(100, 600, 0.1 ether);
        cfgs[2] = _nthCfg(100, 25, 0.1 ether);
        (HookTokenV2 t, PoolKey memory key) = _many(ids, cfgs, 100);
        uint256 n0 = nthPot.potOf(_id(key)).pot;
        uint256 l0 = timerPot.potOf(_id(key)).pot;
        _routerBuy(bob, t, 1 ether);
        assertEq(nthPot.potOf(_id(key)).pot - n0, 0.11 ether);
        assertEq(timerPot.potOf(_id(key)).pot - l0, 0.01 ether);
        assertEq(antiSnipe.guardOf(_id(key)).sink, address(nthPot));

        (HookTokenV2 t2, PoolKey memory key2) =
            _many(_ids2(antiSnipeId, timerPotId), _cfgs2(cfgs[0], cfgs[1]), 100);
        l0 = timerPot.potOf(_id(key2)).pot;
        _routerBuy(bob, t2, 1 ether);
        assertEq(timerPot.potOf(_id(key2)).pot - l0, 0.11 ether);
    }

    function test_potWinnerTakesSnipeTax() public {
        (HookTokenV2 t, PoolKey memory key) =
            _many(_ids2(antiSnipeId, nthPotId), _cfgs2(_antiSnipeCfg(150, 0, 1_000), _nthCfg(100, 3, 0.1 ether)), 100);
        uint256 pot0 = nthPot.potOf(_id(key)).pot; // curve buys: count 1
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(bob, t, 1 ether); // count 2: pot + 0.11
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(alice, t, 1 ether); // count 3: wins the pot + this buy's share 0.01
        // This buy's own snipe tax (0.1) is announced in the same callback, before the hook books (and maybe
        // scales) it: it is never paid out unverified, so it starts the next round's pot.
        assertEq(hook.claimable(alice, NATIVE), pot0 + 0.12 ether);
        assertEq(nthPot.potOf(_id(key)).pot, 0.1 ether);
        nthPot.reconcile();
        assertEq(nthPot.potOf(_id(key)).pot, 0.1 ether);
        assertEq(hook.claimable(address(nthPot), NATIVE), 0.1 ether);
    }

    function test_onlyPoolModulesCanFundAPot_andUnbookedFundingIsRemoved() public {
        FakeFunder fake = new FakeFunder(address(hook));
        uint32 fakeId = modules.addModule(address(fake), '{"name":"fake"}');
        (HookTokenV2 t, PoolKey memory key) =
            _many(_ids2(fakeId, nthPotId), _cfgs2("", _nthCfg(100, 25, 0.1 ether)), 100);
        PoolId id = _id(key);
        // a stranger, or a module of another pool, can't fund it
        vm.prank(alice);
        vm.expectRevert(NthBuyPotModule.NotPoolModule.selector);
        nthPot.addSnipeTax(id, 1 ether);
        (, PoolKey memory other) = _one(nthPotId, _nthCfg(100, 25, 0.1 ether));
        vm.expectRevert(NthBuyPotModule.NotPoolModule.selector);
        fake.cheat(nthPot, _id(other), 1 ether);
        // a module of the pool that announces funding without crediting it: counted, then removed
        uint256 pot0 = nthPot.potOf(id).pot;
        _routerBuy(bob, t, 1 ether);
        fake.cheat(nthPot, id, 50 ether);
        assertEq(nthPot.potOf(id).pot - pot0, 50.01 ether);
        _routerBuy(bob, t, 1 ether); // the next pot action reconciles first
        assertEq(nthPot.potOf(id).pot - pot0, 0.02 ether);
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
    }

    function test_disabledSinkFallsBackToProtocol() public {
        (HookTokenV2 t, PoolKey memory key) =
            _many(_ids2(antiSnipeId, nthPotId), _cfgs2(_antiSnipeCfg(150, 0, 1_000), _nthCfg(100, 25, 0.1 ether)), 100);
        modules.disable(nthPotId);
        uint256 p0 = hook.claimable(hook.PROTOCOL(), NATIVE);
        uint256 pot0 = nthPot.potOf(_id(key)).pot;
        _routerBuy(bob, t, 1 ether);
        assertEq(hook.claimable(hook.PROTOCOL(), NATIVE) - p0, 0.003 ether + 0.1 ether);
        assertEq(nthPot.potOf(_id(key)).pot, pot0);
    }

    // v1: nobody else may add liquidity during the guard.
    function test_liquidityLockedDuringGuard() public {
        (HookTokenV2 t, PoolKey memory key) = _guarded();
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        _routerBuy(carol, t, 5 ether);
        vm.startPrank(carol);
        t.approve(address(lp), type(uint256).max);
        int24 lo = TickMath.minUsableTick(60);
        int24 hi = TickMath.maxUsableTick(60);
        vm.expectRevert();
        lp.modifyLiquidity{value: 1 ether}(key, ModifyLiquidityParams(lo, hi, 1e17, 0), "");
        vm.roll(vm.getBlockNumber() + 150);
        lp.modifyLiquidity{value: 1 ether}(key, ModifyLiquidityParams(lo, hi, 1e17, 0), "");
        vm.stopPrank();
    }

    function test_configBounds() public {
        vm.expectRevert();
        antiSnipe.validateConfig(_antiSnipeCfg(0, 1 ether, 100));
        vm.expectRevert();
        antiSnipe.validateConfig(_antiSnipeCfg(7_201, 1 ether, 100));
        vm.expectRevert();
        antiSnipe.validateConfig(_antiSnipeCfg(150, 1 ether, 2_501));
        antiSnipe.validateConfig(_antiSnipeCfg(7_200, 0, 2_500));
        assertEq(antiSnipe.capabilities() & ModuleCaps.BLOCKS_SELLS, 0);
    }

    /// Audit fix: a buy+sell round trip in one transaction no longer fills the per-block cap (net buying).
    function test_roundTripDoesntFillTheCap() public {
        (HookTokenV2 t, PoolKey memory key) = _guarded();
        RoundTripper g = new RoundTripper(router);
        vm.deal(address(g), 5 ether);
        g.roundTrip(address(t), 5 ether); // takes the whole 5 AVAX cap, then sells it all back
        uint256 left = antiSnipe.guardOf(_id(key)).spent;
        assertLt(left, 1 ether, "only the fees and tax stay counted");
        _routerBuy(carol, t, 4 ether); // an honest buyer still gets in this block
        vm.expectRevert();
        _routerBuy(carol, t, 5 ether - left - 4 ether + 1); // the cap still holds on net buying
    }

    /// A sell can't free another block's count.
    function test_sellsOnlyFreeThisBlocksCount() public {
        (HookTokenV2 t, PoolKey memory key) = _guarded();
        uint256 got = _routerBuy(bob, t, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        _routerSell(bob, t, got); // a new block: nothing counted to free
        assertEq(antiSnipe.guardOf(_id(key)).spent, 5 ether);
        vm.expectRevert();
        _routerBuy(carol, t, 5 ether + 1); // still capped at 5 for the new block
        _routerBuy(carol, t, 5 ether);
    }

    /// Final audit: another wallet's sell (another transaction) gives no room to a sniper; only a sell netting
    /// its own transaction's buys does.
    /// forge-config: default.isolate = true
    function test_othersSellsDontFreeTheCap() public {
        (HookTokenV2 t, PoolKey memory key) = _guarded();
        uint256 got = _routerBuy(alice, t, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(bob, t, 4 ether); // 4 of the 5 AVAX cap in this block
        _routerSell(alice, t, got); // an honest exit in the same block, separate transaction
        assertEq(antiSnipe.guardOf(_id(key)).spent, 4 ether, "other sells free nothing");
        vm.expectRevert();
        _routerBuy(bob, t, 1 ether + 1);
    }
}
