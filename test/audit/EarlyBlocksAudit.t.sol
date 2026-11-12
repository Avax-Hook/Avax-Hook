// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {ResonanceModule} from "../../contracts/v2/modules/ResonanceModule.sol";
import {AntiBundleModule} from "../../contracts/v2/modules/AntiBundleModule.sol";
import {RedLightModule} from "../../contracts/v2/modules/RedLightModule.sol";
import {EarlyBlocksBase} from "../v2/EarlyBlocksBase.t.sol";

/// Buys on the curve several times in ONE transaction.
contract CurveSplitBuyer {
    HookLaunchpadV2 immutable pad;

    constructor(HookLaunchpadV2 _pad) {
        pad = _pad;
    }

    receive() external payable {}

    function buyN(address token, uint256 each, uint256 n) external payable {
        for (uint256 i; i < n; ++i) {
            pad.buy{value: each}(token, 0);
        }
    }
}

/// Audit PoCs for the package-3 modules, inverted to prove the fixes. Each top-level call is its own transaction (per-tx tallies).
/// forge-config: default.isolate = true
contract EarlyBlocksAuditTest is EarlyBlocksBase {
    ResonanceModule rs;
    AntiBundleModule ab;
    RedLightModule rl;
    uint32 rsId;
    uint32 abId;
    uint32 rlId;

    uint256 constant BASE = 20_000_000 ether; // 2% of supply

    function setUp() public override {
        super.setUp();
        rs = new ResonanceModule(address(hook));
        rsId = modules.addModule(address(rs), '{"name":"Resonance"}');
        ab = new AntiBundleModule(address(hook));
        abId = modules.addModule(address(ab), '{"name":"Anti-bundle"}');
        rl = new RedLightModule(address(hook));
        rlId = modules.addModule(address(rl), '{"name":"Red light"}');
    }

    /// AVAX needed on the curve right now to receive about `tokens` (gross of the 0.3% fee).
    function _quoteFor(HookTokenV2 t, uint256 tokens) internal view returns (uint256) {
        HookLaunchpadV2.Launch memory l = pad.getLaunch(address(t));
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        uint256 net = (x * tokens) / (y - tokens);
        return (net * 10_000) / (10_000 - 30 - l.creatorFeeBps);
    }

    // ------------------------------------------------------------------ Resonance: intra-tx cap ramp

    function _resonanceToken() internal returns (HookTokenV2 t) {
        t = _launch(_one(rsId), _oneCfg(abi.encode(ResonanceModule.Config(200, 50, 120, 1, 10_000, 10_000, 2_500))), 0);
        _curveBuy(alice, t, _quoteFor(t, BASE / 2)); // start the swing with a half-base buy
    }

    /// FIXED (was: 12 split curve buys in one tx passed ~2.85x base against a 1.5x cap). The cap is now fixed
    /// at the first buy of each second, so pushes inside the transaction no longer widen it.
    function test_resonance_splitBuyCannotRampCap() public {
        HookTokenV2 t = _resonanceToken();
        vm.warp(vm.getBlockTimestamp() + 30); // quarter beat: peak
        uint256 cap0 = rs.currentCap(address(t));
        assertLt(cap0, (BASE * 16) / 10); // ~1.5 base

        CurveSplitBuyer m = new CurveSplitBuyer(pad);
        uint256 each = _quoteFor(t, BASE / 4);
        vm.deal(address(m), each * 12 + 1 ether);
        vm.expectRevert(); // ~3 base split into 12 swaps: refused like one big buy
        m.buyN(address(t), each, 12);
        // a split buy that fits the starting cap goes through, and the cap stays fixed for the second
        m.buyN(address(t), each, 5); // ~1.25 base
        uint256 got = t.balanceOf(address(m));
        assertLe(got, cap0);
        assertEq(rs.currentCap(address(t)), cap0);
        // a second transaction in the same second can't use a pushed-up cap either
        CurveSplitBuyer m2 = new CurveSplitBuyer(pad);
        uint256 each2 = _quoteFor(t, (cap0 * 11) / 40); // 4 x 0.275 cap0 = 1.1 cap0
        vm.deal(address(m2), each2 * 4 + 1 ether);
        vm.expectRevert();
        m2.buyN(address(t), each2, 4);
        // from the next second the pushes count
        vm.warp(vm.getBlockTimestamp() + 1);
        assertGt(rs.currentCap(address(t)), cap0);
    }

    /// FIXED (was: at a trough, off-beat pushes deepened it mid-transaction and refused a split buy whose total
    /// was under the cap the transaction started with).
    function test_resonance_splitBuyAtTroughFitsStartingCap() public {
        HookTokenV2 t = _resonanceToken();
        vm.warp(vm.getBlockTimestamp() + 90); // three quarters: trough
        uint256 cap0 = rs.currentCap(address(t));
        assertLt(cap0, BASE);
        CurveSplitBuyer m = new CurveSplitBuyer(pad);
        uint256 each = _quoteFor(t, (cap0 * 9) / 50); // 5 x 0.18 cap0 = 0.9 cap0
        vm.deal(address(m), each * 5 + 1 ether);
        m.buyN(address(t), each, 5);
        assertLe(t.balanceOf(address(m)), cap0);
    }

    // ------------------------------------------------------------------ Anti-bundle: dust griefing

    /// FIXED (was: one 1-gwei buy per block took the only place, forever). Dust under minBuyBps passes
    /// uncounted; "forever" (blocks = 0) is no longer a valid config.
    function test_antiBundle_dustBuyNoLongerTakesTheBlock() public {
        vm.expectRevert();
        ab.validateConfig(abi.encode(AntiBundleModule.Config(1, 0, 5)));
        HookTokenV2 t = _launch(_one(abId), _oneCfg(abi.encode(AntiBundleModule.Config(1, 43_200, 5))), 0);
        for (uint256 b; b < 5; ++b) {
            vm.roll(vm.getBlockNumber() + 1);
            address griefer = address(0xBAD);
            vm.deal(griefer, 1 ether);
            vm.prank(griefer);
            pad.buy{value: 1e9}(address(t), 0); // 1 gwei of AVAX
            // the honest 1 AVAX buy in the same block goes through
            vm.deal(alice, 2 ether);
            vm.prank(alice);
            pad.buy{value: 1 ether}(address(t), 0);
        }
    }

    // ------------------------------------------------------------------ Red light: views

    /// FIXED: currentSlot() returns 0 for a token that isn't on the module. Also measures nextChange() view gas.
    function test_redLight_views() public {
        assertEq(rl.currentSlot(address(0x1234)), 0);
        assertTrue(rl.isGreen(address(0x1234)));
        assertEq(rl.nextChange(address(0x1234)), 0);

        HookTokenV2 t = _launch(_one(rlId), _oneCfg(abi.encode(RedLightModule.Config(60, 1_000, 60, false))), 0);
        uint256 worst;
        for (uint256 i; i < 200; ++i) {
            vm.warp(vm.getBlockTimestamp() + 60);
            uint256 g = gasleft();
            rl.nextChange(address(t));
            g -= gasleft();
            if (g > worst) worst = g;
        }
        emit log_named_uint("red-light nextChange worst view gas (200 slots, 10% green, maxRed 60)", worst);
    }
}
