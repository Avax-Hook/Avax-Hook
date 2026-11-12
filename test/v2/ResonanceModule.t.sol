// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {ResonanceModule} from "../../contracts/v2/modules/ResonanceModule.sol";
import {MultiSwapper} from "./NewModulesBase.t.sol";
import {EarlyBlocksBase} from "./EarlyBlocksBase.t.sol";

/// Resonance in the live hook. Isolated: each top-level call is its own transaction (per-tx caps).
/// forge-config: default.isolate = true
contract ResonanceModuleTest is EarlyBlocksBase {
    ResonanceModule rs;
    uint32 rsId;
    HookTokenV2 t;
    PoolKey key;

    uint256 constant BASE = 20_000_000 ether; // 2%
    uint256 constant FLOOR = 5_000_000 ether; // 0.5%
    uint32 constant BEAT = 120;

    function setUp() public override {
        super.setUp();
        rs = new ResonanceModule(address(hook));
        rsId = modules.addModule(address(rs), '{"name":"Resonance"}');
        (t, key) = _launchCapped(rsId, _cfg(200, 50, BEAT, 10, 4_000, 500, 500), (BASE * 95) / 100, 0);
    }

    function _cfg(uint16 base, uint16 floor, uint32 beat, uint16 damp, uint16 on, uint16 off, uint16 window)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(ResonanceModule.Config(base, floor, beat, damp, on, off, window));
    }

    function _fresh() internal returns (HookTokenV2 t2) {
        t2 = _launch(_one(rsId), _oneCfg(_cfg(200, 50, BEAT, 10, 4_000, 500, 500)), 0);
    }

    function _push(HookTokenV2 tok, uint256 amountOut) internal {
        IHookModule.SwapContext memory c;
        c.poolId = rs.poolOf(address(tok));
        c.token = address(tok);
        c.isBuy = true;
        c.amountOut = amountOut;
        vm.prank(address(hook));
        rs.onAfterSwap(c);
    }

    function _radius(HookTokenV2 tok) internal view returns (uint256) {
        (int256 a, int256 b) = rs.state(address(tok));
        return Math.sqrt(uint256(a * a + b * b));
    }

    function test_capabilities() public view {
        assertEq(rs.capabilities(), ModuleCaps.AFTER_SWAP);
        assertEq(rs.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
    }

    function test_firstBuyStartsTheBeat() public {
        HookTokenV2 t2 = _fresh();
        assertTrue(rs.onBeatNow(address(t2))); // at rest: the first buy counts as on the beat
        _push(t2, BASE / 2);
        (int256 a, int256 b) = rs.state(address(t2));
        assertEq(a, 0);
        assertEq(b, 0.2e18); // 0.4 · 0.5
        assertFalse(rs.onBeatNow(address(t2))); // swing at zero, rising
        assertEq(rs.nextBeatIn(address(t2)), BEAT / 4);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + BEAT / 4);
        assertTrue(rs.onBeatNow(address(t2)));
        assertGt(rs.currentCap(address(t2)), BASE);
        vm.warp(t0 + BEAT / 4 + 10); // past the 6 s window
        assertFalse(rs.onBeatNow(address(t2)));
    }

    /// The same buy pushes on-beat 8x harder than off-beat (energyOnBeat / energyOffBeat).
    function test_onBeatPushesHarder() public {
        HookTokenV2 t2 = _fresh();
        _push(t2, BASE / 2);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + BEAT / 4); // peak
        uint256 r0 = _radius(t2);
        _push(t2, BASE / 2);
        uint256 onGain = _radius(t2) - r0;
        assertApproxEqAbs(onGain, 0.2e18, 1e12);
        vm.warp(t0 + BEAT / 4 + BEAT / 4); // zero crossing: off the beat
        r0 = _radius(t2);
        _push(t2, BASE / 2);
        uint256 offGain = _radius(t2) - r0;
        assertApproxEqAbs(offGain, 0.025e18, 1e12);
    }

    /// Buying on every peak opens the cap far more than the same buys off the beat.
    function test_rhythmBeatsRandom() public {
        HookTokenV2 onT = _fresh();
        HookTokenV2 offT = _fresh();
        uint256 t0 = vm.getBlockTimestamp();
        _push(onT, BASE / 2);
        _push(offT, BASE / 2);
        for (uint256 n; n < 5; ++n) {
            vm.warp(t0 + BEAT / 4 + n * BEAT); // peaks
            assertTrue(rs.onBeatNow(address(onT)));
            _push(onT, BASE / 2);
            vm.warp(t0 + (n + 1) * BEAT); // rising zero crossings: off the beat
            assertFalse(rs.onBeatNow(address(offT)));
            _push(offT, BASE / 2);
        }
        vm.warp(t0 + BEAT / 4 + 5 * BEAT);
        uint256 capOn = rs.currentCap(address(onT));
        uint256 capOff = rs.currentCap(address(offT));
        emit log_named_uint("rhythmic peak cap (x base, 1e18)", (capOn * 1e18) / BASE);
        emit log_named_uint("off-beat peak cap (x base, 1e18)", (capOff * 1e18) / BASE);
        assertGt(capOn, (BASE * 17) / 10);
        assertGt(capOn - BASE, 2 * (capOff - BASE));
    }

    function test_poolBuyCappedAllRoutes() public {
        vm.warp(vm.getBlockTimestamp() + 1 days); // at rest
        assertEq(rs.currentCap(address(t)), BASE);
        bytes memory err = _buyError(alice, t, 150 ether); // ~2.6% of supply
        assertTrue(_has(err, ResonanceModule.BuyCapExceeded.selector));
        vm.expectRevert();
        agg.swap(key, true, -int256(150 ether));
        _routerBuy(alice, t, 50 ether);
        agg.swap(key, true, -int256(10 ether));
    }

    function test_curveBuysCapped() public {
        HookTokenV2 t2 = _fresh();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 20 ether}(address(t2), 0);
        _curveBuy(alice, t2, 4 ether);
        assertGt(_radius(t2), 0);
    }

    function test_splitBuysInOneTxCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 200 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        try m.buyTwice{value: 120 ether}(address(t), 60 ether, 60 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, ResonanceModule.BuyCapExceeded.selector));
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
        (int256 a0, int256 b0) = rs.state(address(t));
        _routerSell(h, t, bal);
        (int256 a1, int256 b1) = rs.state(address(t));
        assertEq(a0, a1);
        assertEq(b0, b1);
    }

    function testFuzz_capWithinBounds(uint256 amt, uint32 wait, uint32 dt) public {
        HookTokenV2 t2 = _fresh();
        for (uint256 i; i < 8; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(uint256(keccak256(abi.encode(wait, i))), 0, 200));
            uint256 cap = rs.currentCap(address(t2));
            uint256 x = bound(amt, 1, 4 * BASE);
            _push(t2, x > cap ? cap : x);
        }
        assertLe(_radius(t2), 3e18 + 1e9);
        uint256 c = rs.capIn(address(t2), bound(dt, 0, 10_000_000));
        assertGe(c, FLOOR);
        assertLe(c, 4 * BASE);
    }

    function test_callbackGas() public {
        HookTokenV2 t2 = _launch(_one(rsId), _oneCfg(_cfg(200, 50, 86_400, 1, 10_000, 100, 2_500)), 0);
        _push(t2, BASE);
        vm.warp(vm.getBlockTimestamp() + 100_000);
        IHookModule.SwapContext memory c;
        c.poolId = rs.poolOf(address(t2));
        c.isBuy = true;
        c.amountOut = FLOOR;
        vm.prank(address(hook));
        uint256 g = gasleft();
        rs.onAfterSwap(c);
        g -= gasleft();
        emit log_named_uint("resonance onAfterSwap worst-case gas", g);
        assertLt(g, 80_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        rs.validateConfig(_cfg(9, 5, 120, 10, 4_000, 500, 500));
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 21, 120, 10, 4_000, 500, 500));
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 5, 9, 10, 4_000, 500, 500));
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 5, 120, 0, 4_000, 500, 500));
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 5, 120, 10, 0, 0, 500));
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 5, 120, 10, 4_000, 4_001, 500)); // off-beat above on-beat
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 5, 120, 10, 4_000, 500, 0));
        vm.expectRevert();
        rs.validateConfig(_cfg(20, 5, 120, 10, 4_000, 500, 2_501));
        rs.validateConfig(_cfg(1_000, 1_000, 86_400, 5_000, 10_000, 10_000, 2_500));
        rs.validateConfig(_cfg(10, 1, 10, 1, 1, 0, 1));
    }
}
