// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {CoupledResonatorModule} from "../../contracts/v2/modules/CoupledResonatorModule.sol";
import {MultiSwapper} from "./NewModulesBase.t.sol";
import {EarlyBlocksBase} from "./EarlyBlocksBase.t.sol";

/// Coupled resonator in the live hook. Isolated: each top-level call is its own transaction (per-tx caps).
/// forge-config: default.isolate = true
contract CoupledResonatorModuleTest is EarlyBlocksBase {
    CoupledResonatorModule cr;
    uint32 crId;
    HookTokenV2 t;
    PoolKey key;

    uint256 constant BASE = 20_000_000 ether; // 2%
    uint256 constant FLOOR = 5_000_000 ether; // 0.5%

    function setUp() public override {
        super.setUp();
        cr = new CoupledResonatorModule(address(hook));
        crId = modules.addModule(address(cr), '{"name":"Coupled resonator"}');
        (t, key) = _launchCapped(crId, _cfg(200, 50, 120, 120, 1_000, 10, 4_000), (BASE * 95) / 100, 0);
    }

    function _cfg(uint16 base, uint16 floor, uint32 pa, uint32 pb, uint16 coupling, uint16 damp, uint16 energy)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(CoupledResonatorModule.Config(base, floor, pa, pb, coupling, damp, energy));
    }

    function _fresh(bytes memory cfg) internal returns (HookTokenV2) {
        return _launch(_one(crId), _oneCfg(cfg), 0);
    }

    function _kick(HookTokenV2 tok, uint256 amountOut) internal {
        IHookModule.SwapContext memory c;
        c.poolId = cr.poolOf(address(tok));
        c.token = address(tok);
        c.isBuy = true;
        c.amountOut = amountOut;
        vm.prank(address(hook));
        cr.onAfterSwap(c);
    }

    function test_capabilities() public view {
        assertEq(cr.capabilities(), ModuleCaps.AFTER_SWAP);
        assertEq(cr.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
    }

    function test_kickSwellsTheCap() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 120, 120, 1_000, 10, 4_000));
        assertEq(cr.currentCap(address(t2)), BASE);
        _kick(t2, BASE / 2);
        (int256 ar, int256 ai, int256 br, int256 bi) = cr.state(address(t2));
        assertEq(ar, 0);
        assertEq(ai, -0.2e18);
        assertEq(br, 0);
        assertEq(bi, 0);
        vm.warp(vm.getBlockTimestamp() + 30); // a quarter period later the cap is wider
        assertGt(cr.currentCap(address(t2)), (BASE * 115) / 100);
    }

    /// Equal periods, 10% coupling: the whole swing moves to B in period / (4 · 0.1) = 300 s and back by 600 s.
    function test_energyFlowsToBAndBack() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 120, 120, 1_000, 1, 4_000));
        _kick(t2, BASE);
        uint256 t0 = vm.getBlockTimestamp();
        (uint256 e0,) = cr.energies(address(t2));
        assertApproxEqRel(e0, 0.16e18, 1e12);
        vm.warp(t0 + 150);
        (uint256 ea, uint256 eb) = cr.energies(address(t2));
        assertApproxEqRel(ea, eb, 2e16); // half way
        vm.warp(t0 + 300);
        (ea, eb) = cr.energies(address(t2));
        assertLt(ea, eb / 100); // all in B
        uint256 d = 970_444_077_784_251_136; // 0.9999^300
        assertApproxEqRel(ea + eb, (e0 * d * d) / 1e36, 2e15); // only damping takes energy out
        vm.warp(t0 + 600);
        (ea, eb) = cr.energies(address(t2));
        assertGt(ea, eb * 100); // back in A
    }

    /// The cap swells and fades in beats: the swing of Re(A + B) goes as sqrt(1 + sin(2θ)), θ = 2π · s / 1200
    /// here, so it peaks around 150 s, dies out around 450 s and is back around 750 s.
    function test_capBeats() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 120, 120, 1_000, 1, 4_000));
        _kick(t2, BASE);
        uint256 swell = _maxCap(t2, 90, 210);
        uint256 lull = _maxCap(t2, 400, 500);
        uint256 again = _maxCap(t2, 690, 810);
        emit log_named_uint("swell (x base, 1e18)", (swell * 1e18) / BASE);
        emit log_named_uint("lull (x base, 1e18)", (lull * 1e18) / BASE);
        assertGt(swell, (BASE * 150) / 100); // above the kick's own 1.4x
        assertLt(lull, (BASE * 116) / 100);
        assertGt(again, (BASE * 150) / 100);
    }

    function _maxCap(HookTokenV2 tok, uint256 from, uint256 to) internal view returns (uint256 top) {
        for (uint256 s = from; s < to; s += 2) {
            uint256 c = cr.capIn(address(tok), s);
            if (c > top) top = c;
        }
    }

    /// Different periods: only part of the swing reaches B.
    function test_detunedTransferIsPartial() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 60, 120, 1_000, 1, 4_000));
        _kick(t2, BASE);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 maxB;
        for (uint256 s; s < 400; s += 5) {
            vm.warp(t0 + s);
            (uint256 ea, uint256 eb) = cr.energies(address(t2));
            if (eb * 1e18 / (ea + eb) > maxB) maxB = (eb * 1e18) / (ea + eb);
        }
        assertGt(maxB, 0.05e18);
        assertLt(maxB, 0.5e18);
    }

    function test_poolBuyCappedAllRoutes() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(cr.currentCap(address(t)), BASE);
        bytes memory err = _buyError(alice, t, 150 ether);
        assertTrue(_has(err, CoupledResonatorModule.BuyCapExceeded.selector));
        vm.expectRevert();
        agg.swap(key, true, -int256(150 ether));
        _routerBuy(alice, t, 50 ether);
        agg.swap(key, true, -int256(10 ether));
    }

    function test_curveBuysCapped() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 120, 120, 1_000, 10, 4_000));
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 20 ether}(address(t2), 0);
        _curveBuy(alice, t2, 4 ether);
        (, int256 ai,,) = cr.state(address(t2));
        assertLt(ai, 0);
    }

    function test_splitBuysInOneTxCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 200 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        try m.buyTwice{value: 120 ether}(address(t), 60 ether, 60 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, CoupledResonatorModule.BuyCapExceeded.selector));
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
        uint256 bal = t.balanceOf(h);
        assertGt(bal, 4 * BASE);
        uint256 c0 = cr.currentCap(address(t));
        _routerSell(h, t, bal);
        assertEq(cr.currentCap(address(t)), c0);
    }

    function test_amplitudeIsBounded() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 60, 90, 2_000, 1, 10_000));
        for (uint256 i; i < 40; ++i) {
            _kick(t2, cr.currentCap(address(t2)));
            vm.warp(vm.getBlockTimestamp() + 3);
        }
        (int256 ar, int256 ai, int256 br, int256 bi) = cr.state(address(t2));
        assertLe(uint256(ar * ar + ai * ai + br * br + bi * bi), 4.01e36);
        for (uint256 dt; dt < 600; dt += 7) {
            uint256 c = cr.capIn(address(t2), dt);
            assertGe(c, FLOOR);
            assertLe(c, 4 * BASE);
        }
    }

    function testFuzz_capWithinBounds(uint256 amt, uint32 wait, uint32 pa, uint32 pb, uint16 cpl, uint32 dt) public {
        HookTokenV2 t2 = _fresh(
            _cfg(200, 50, uint32(bound(pa, 10, 86_400)), uint32(bound(pb, 10, 86_400)), uint16(bound(cpl, 1, 5_000)), 5, 10_000)
        );
        for (uint256 i; i < 6; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(uint256(keccak256(abi.encode(wait, i))), 0, 500));
            uint256 cap = cr.currentCap(address(t2));
            uint256 x = bound(amt, 1, 4 * BASE);
            _kick(t2, x > cap ? cap : x);
        }
        uint256 c = cr.capIn(address(t2), bound(dt, 0, 10_000_000));
        assertGe(c, FLOOR);
        assertLe(c, 4 * BASE);
    }

    function test_callbackGas() public {
        HookTokenV2 t2 = _fresh(_cfg(200, 50, 86_400, 77, 1, 1, 10_000));
        _kick(t2, BASE);
        vm.warp(vm.getBlockTimestamp() + 100_000);
        IHookModule.SwapContext memory c;
        c.poolId = cr.poolOf(address(t2));
        c.isBuy = true;
        c.amountOut = FLOOR;
        vm.prank(address(hook));
        uint256 g = gasleft();
        cr.onAfterSwap(c);
        g -= gasleft();
        emit log_named_uint("coupled onAfterSwap worst-case gas", g);
        assertLt(g, 100_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        cr.validateConfig(_cfg(9, 5, 120, 120, 1_000, 10, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 21, 120, 120, 1_000, 10, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 5, 9, 120, 1_000, 10, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 5, 120, 86_401, 1_000, 10, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 5, 120, 120, 0, 10, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 5, 120, 120, 5_001, 10, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 5, 120, 120, 1_000, 0, 4_000));
        vm.expectRevert();
        cr.validateConfig(_cfg(20, 5, 120, 120, 1_000, 10, 10_001));
        cr.validateConfig(_cfg(1_000, 1_000, 86_400, 10, 5_000, 5_000, 10_000));
    }
}
