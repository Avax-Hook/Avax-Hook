// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {MomentumModule} from "../../contracts/v2/modules/MomentumModule.sol";
import {ModuleMath} from "../../contracts/v2/modules/lib/ModuleMath.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

contract TrigHarness {
    function sinTurn(uint256 x) external pure returns (int256) {
        return ModuleMath.sinTurn(x);
    }

    function cosTurn(uint256 x) external pure returns (int256) {
        return ModuleMath.cosTurn(x);
    }

    function rpow(uint256 b, uint256 e) external pure returns (uint256) {
        return ModuleMath.rpow(b, e);
    }
}

contract ModuleMathTest is Test {
    TrigHarness h = new TrigHarness();

    function test_sinKnownValues() public view {
        assertEq(h.sinTurn(0), 0);
        assertEq(h.sinTurn(0.25e18), 1e18);
        assertEq(h.sinTurn(0.5e18), 0);
        assertEq(h.sinTurn(0.75e18), -1e18);
        assertApproxEqAbs(h.sinTurn(uint256(1e18) / 12), 0.5e18, 8e13); // 30 deg
        assertApproxEqAbs(h.sinTurn(0.125e18), 707106781186547524, 8e13); // 45 deg
        assertApproxEqAbs(h.sinTurn(uint256(1e18) / 6), 866025403784438647, 8e13); // 60 deg
        assertApproxEqAbs(h.sinTurn(uint256(7e18) / 12), -0.5e18, 8e13); // 210 deg
        assertApproxEqAbs(h.cosTurn(uint256(1e18) / 6), 0.5e18, 8e13);
        assertEq(h.cosTurn(0), 1e18);
        assertEq(h.sinTurn(1.25e18), 1e18); // wraps
    }

    /// sin² + cos² = 1 and odd symmetry, everywhere.
    function testFuzz_trigIdentities(uint256 x) public view {
        x = bound(x, 0, 1e18 - 1);
        int256 s = h.sinTurn(x);
        int256 c = h.cosTurn(x);
        assertLe(s < 0 ? -s : s, 1e18);
        assertApproxEqAbs((s * s + c * c) / 1e18, 1e18, 2e14);
        assertApproxEqAbs(h.sinTurn(1e18 - x), x == 0 ? int256(0) : -s, 1);
    }

    function test_rpow() public view {
        assertEq(h.rpow(0.5e18, 3), 0.125e18);
        assertApproxEqRel(h.rpow(0.99e18, 30), 739700373388280000, 1e12);
        assertEq(h.rpow(0.9e18, 0), 1e18);
        assertEq(h.rpow(0.5e18, 1 << 40), 0);
    }
}

/// Momentum in the live hook. Isolated: each top-level call is its own transaction (per-tx caps).
/// forge-config: default.isolate = true
contract MomentumModuleTest is NewModulesBase {
    MomentumModule mo;
    uint32 moId;
    HookTokenV2 t;
    PoolKey key;

    uint256 constant BASE = 20_000_000 ether; // 2%
    uint256 constant FLOOR = 5_000_000 ether; // 0.5%

    function setUp() public override {
        super.setUp();
        mo = new MomentumModule(address(hook));
        moId = modules.addModule(address(mo), '{"name":"Momentum"}');
        // the cap runs on the curve too: fill it with buys under the resting cap
        (t, key) = _launchCapped(moId, _cfg(200, 50, 120, 100, 4000), (BASE * 95) / 100, 0);
    }

    function _cfg(uint16 base, uint16 floor, uint32 period, uint16 damp, uint16 energy) internal pure returns (bytes memory) {
        return abi.encode(MomentumModule.Config(base, floor, period, damp, energy));
    }

    function _ctx(uint256 amountOut) internal view returns (IHookModule.SwapContext memory c) {
        c.poolId = _id(key);
        c.token = address(t);
        c.isBuy = true;
        c.amountOut = amountOut;
        c.txSwaps = 1;
    }

    function test_capabilities() public view {
        assertEq(mo.capabilities(), ModuleCaps.AFTER_SWAP);
        assertEq(mo.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
    }

    function test_restingCapIsBase() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours); // let the curve's kicks die down
        assertEq(mo.currentCap(address(t)), BASE);
        bytes memory err = _buyError(alice, t, 150 ether); // ~2.6% of supply
        assertTrue(_has(err, MomentumModule.BuyCapExceeded.selector));
        _routerBuy(alice, t, 50 ether);
    }

    function test_curveBuysAreCapped() public {
        HookTokenV2 t2 = _launch(_one(moId), _oneCfg(_cfg(200, 50, 120, 100, 4000)), 0);
        vm.prank(alice);
        vm.expectRevert(); // ~8% of supply in one curve buy
        pad.buy{value: 20 ether}(address(t2), 0);
        vm.prank(alice);
        pad.buy{value: 4 ether}(address(t2), 0); // ~1.8%
        (, int256 b) = mo.state(address(t2));
        assertGt(b, 0); // and it kicked the oscillator
    }

    /// One kick from rest: x(s) = k · 0.99^s · sin(2πs/120), k = 0.4 · amount / base.
    function test_swingFollowsTheOscillator() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours); // at rest
        uint256 got = _routerBuy(alice, t, 50 ether);
        int256 k = int256((4000 * got * 1e18) / (10_000 * BASE));
        (int256 a, int256 b) = mo.state(address(t));
        assertEq(a, 0);
        assertEq(b, k);
        uint256 t0 = vm.getBlockTimestamp(); // (via-IR may re-read TIMESTAMP after a warp)
        vm.warp(t0 + 30); // quarter period: peak
        uint256 expect = BASE + (BASE * uint256(k) * 739700373388280000) / 1e36;
        assertApproxEqRel(mo.currentCap(address(t)), expect, 1e15);
        assertGt(mo.currentCap(address(t)), BASE);
        vm.warp(t0 + 60); // half: back through base
        assertApproxEqRel(mo.currentCap(address(t)), BASE, 1e15);
        vm.warp(t0 + 90); // three quarters: trough (0.99^90 = 0.40473)
        uint256 trough = BASE - (BASE * uint256(k) * 404731619658700000) / 1e36;
        assertApproxEqRel(mo.currentCap(address(t)), trough, 1e15);
        vm.warp(t0 + 3600); // an hour later: at rest
        assertEq(mo.currentCap(address(t)), BASE);
    }

    function test_kickLetsBiggerBuysThrough() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours); // at rest
        uint256 big = (BASE * 115) / 100;
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(MomentumModule.BuyCapExceeded.selector, big, BASE));
        mo.onAfterSwap(_ctx(big));
        _routerBuy(alice, t, 80 ether); // a near-base buy kicks it
        vm.warp(vm.getBlockTimestamp() + 30);
        assertGt(mo.currentCap(address(t)), big);
        vm.prank(address(hook));
        mo.onAfterSwap(_ctx(big)); // the same buy fits now
    }

    function test_splitBuysInOneTxCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 100 ether);
        // two ~0.15% buys: each fits, together they don't
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        try m.buyTwice{value: 120 ether}(address(t), 60 ether, 60 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, MomentumModule.BuyCapExceeded.selector));
        }
        _routerBuy(alice, t, 60 ether);
    }

    function test_sellsNeverCapped() public {
        address h = _holder(0);
        for (uint256 i = 1; i < 10; ++i) {
            address w = _holder(i);
            uint256 b = t.balanceOf(w);
            vm.prank(w);
            t.transfer(h, b);
        }
        uint256 bal = t.balanceOf(h); // far over any cap
        assertGt(bal, 4 * BASE);
        uint256 a0 = mo.currentCap(address(t));
        _routerSell(h, t, bal);
        assertEq(mo.currentCap(address(t)), a0); // and they don't move the oscillator
    }

    /// Pumping with max-size buys on every beat: the amplitude saturates, the cap stays in [floor, 4·base].
    function test_amplitudeIsBounded() public {
        for (uint256 i; i < 40; ++i) {
            uint256 cap = mo.currentCap(address(t));
            vm.prank(address(hook));
            mo.onAfterSwap(_ctx(cap));
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        (int256 a, int256 b) = mo.state(address(t));
        assertLe(uint256(a * a + b * b), 9e36 + 1e30); // radius <= 3 (rounding)
        for (uint256 dt; dt < 240; dt += 7) {
            uint256 c = mo.capIn(address(t), dt);
            assertGe(c, FLOOR);
            assertLe(c, 4 * BASE);
        }
        // the trough hits the floor
        bool floored;
        for (uint256 dt; dt < 240; ++dt) {
            if (mo.capIn(address(t), dt) == FLOOR) floored = true;
        }
        assertTrue(floored);
    }

    function testFuzz_capWithinBounds(uint256 amt, uint32 wait, uint32 dt) public {
        amt = bound(amt, 1, 4 * BASE);
        vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 1000));
        uint256 cap = mo.currentCap(address(t));
        if (amt > cap) amt = cap;
        vm.prank(address(hook));
        mo.onAfterSwap(_ctx(amt));
        uint256 c = mo.capIn(address(t), bound(dt, 0, 10_000_000));
        assertGe(c, FLOOR);
        assertLe(c, 4 * BASE);
    }

    /// Worst-case callback gas: a long gap with the slowest damping (deep power loop) and a kick.
    function test_callbackGas() public {
        (HookTokenV2 t2, PoolKey memory k2) = _launchCapped(moId, _cfg(200, 50, 86_400, 1, 10_000), (BASE * 95) / 100, 0);
        IHookModule.SwapContext memory c = _ctx(BASE);
        c.poolId = _id(k2);
        c.token = address(t2);
        vm.prank(address(hook));
        mo.onAfterSwap(c);
        vm.warp(vm.getBlockTimestamp() + 100_000); // 0.9999^100000 ~ 4.5e-5: still swinging, 17-step power
        c.amountOut = FLOOR;
        vm.prank(address(hook));
        uint256 g = gasleft();
        mo.onAfterSwap(c);
        g -= gasleft();
        emit log_named_uint("momentum onAfterSwap worst-case gas", g);
        assertLt(g, 60_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        mo.validateConfig(_cfg(9, 5, 120, 100, 4000));
        vm.expectRevert();
        mo.validateConfig(_cfg(20, 21, 120, 100, 4000)); // floor above base
        vm.expectRevert();
        mo.validateConfig(_cfg(20, 0, 120, 100, 4000));
        vm.expectRevert();
        mo.validateConfig(_cfg(20, 5, 9, 100, 4000));
        vm.expectRevert();
        mo.validateConfig(_cfg(20, 5, 120, 5001, 4000));
        vm.expectRevert();
        mo.validateConfig(_cfg(20, 5, 120, 100, 10_001));
        mo.validateConfig(_cfg(1000, 1000, 86_400, 5000, 10_000));
    }
}
