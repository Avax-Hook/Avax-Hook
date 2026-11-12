// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {ArcadeModule} from "../../contracts/v2/modules/ArcadeModule.sol";
import {ArcadeScores} from "../../contracts/v2/arcade/ArcadeScores.sol";
import {LightsOutGame} from "../../contracts/v2/arcade/LightsOutGame.sol";
import {Game2048} from "../../contracts/v2/arcade/Game2048.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract ArcadeModuleTest is NewModulesBase {
    ArcadeScores scores;
    ArcadeModule arcade;
    LightsOutGame lo;
    Game2048 g2048;
    uint32 arcadeId;
    address safe = makeAddr("safe");

    function setUp() public override {
        super.setUp();
        // deploy order: ArcadeScores -> games -> module; then the Safe allow-lists games and the binder
        scores = new ArcadeScores(safe);
        lo = new LightsOutGame();
        g2048 = new Game2048();
        arcade = new ArcadeModule(address(hook), scores);
        vm.startPrank(safe);
        scores.setGame(address(lo), true);
        scores.setGame(address(g2048), true);
        scores.setBinder(address(arcade), true);
        vm.stopPrank();
        arcadeId = modules.addModule(address(arcade), '{"name":"Arcade"}');
    }

    function _cfg(address game, uint32 unlock, uint16 capBps, bool untilGrad) internal pure returns (bytes memory) {
        return abi.encode(ArcadeModule.Config(game, unlock, capBps, untilGrad, false));
    }

    function _cfgEx(address game, uint32 unlock, uint16 capBps, bool untilGrad) internal pure returns (bytes memory) {
        return abi.encode(ArcadeModule.Config(game, unlock, capBps, untilGrad, true));
    }

    function _loSolution(bytes32 seed) internal pure returns (bytes memory inputs) {
        uint256 presses = uint256(seed) & ((1 << 25) - 1);
        uint256 n;
        for (uint256 c; c < 25; ++c) {
            if (presses & (1 << c) != 0) ++n;
        }
        inputs = new bytes(n);
        uint256 w;
        for (uint256 c; c < 25; ++c) {
            if (presses & (1 << c) != 0) inputs[w++] = bytes1(uint8(c));
        }
    }

    /// Plays and solves Lights Out for `who` on `t` (the solver-bot path the docs warn about).
    function _unlock(address who, HookTokenV2 t) internal returns (uint256 got) {
        vm.prank(who);
        bytes32 seed = scores.startRun(address(t));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(who);
        got = scores.submitRun(address(t), _loSolution(seed));
    }

    function _curveBuyReverts(address who, HookTokenV2 t, uint256 amt) internal {
        vm.prank(who);
        vm.expectRevert();
        pad.buy{value: amt}(address(t), 0);
    }

    function test_capabilitiesAndBinding() public {
        assertEq(arcade.capabilities(), ModuleCaps.ON_TRANSFER);
        assertEq(arcade.conflictGroups(), ModuleCaps.GROUP_HOLDING_CAP);
        HookTokenV2 t = _launch(_one(arcadeId), _oneCfg(_cfg(address(lo), 50, 10, false)), 0);
        assertEq(scores.gameOf(address(t)), address(lo), "bound at launch");
        (ArcadeModule.Config memory c, uint256 cap, bool active) = arcade.ruleOf(address(t));
        assertEq(c.unlockScore, 50);
        assertEq(cap, SUPPLY / 1_000, "0.1%");
        assertTrue(active);
        // nobody else can bind
        vm.expectRevert(ArcadeScores.NotBinder.selector);
        scores.bind(address(0x1234), address(lo));
    }

    function test_validateConfigBounds() public {
        arcade.validateConfig(_cfg(address(lo), 95, 10, false));
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(lo), 0, 10, false)); // unlock 0
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(lo), 100, 10, false)); // above Lights Out's max score
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(lo), 50, 0, false));
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(lo), 50, 5_001, false));
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(0xBEEF), 50, 10, false)); // not allow-listed
        // 2048: practical ceiling (8,000; strong play reaches 7-9k); anything above is refused
        assertEq(g2048.maxScore(), 8_000);
        arcade.validateConfig(_cfg(address(g2048), 8_000, 10, false));
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(g2048), 8_001, 10, false));
        // Lights Out: 95 (perfect solvers score 85+, 97+ needs a rare seed)
        assertEq(lo.maxScore(), 95);
        vm.expectRevert();
        arcade.validateConfig(_cfg(address(lo), 96, 10, false));
        // a launch with a de-listed game fails
        vm.prank(safe);
        scores.setGame(address(g2048), false);
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Arc";
        a.symbol = "ARC";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(arcadeId);
        a.moduleConfigs = _oneCfg(_cfg(address(g2048), 50, 10, false));
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        vm.expectRevert();
        pad.launch{value: fee}(a);
    }

    // curve phase: capped until the wallet unlocks with a score; the unlock is permanent
    function test_curveCapThenUnlock() public {
        HookTokenV2 t = _launch(_one(arcadeId), _oneCfg(_cfg(address(lo), 50, 10, false)), 0);
        // ~0.1% of supply costs a fraction of the target; 1 AVAX buys far more than 1M tokens at the start
        _curveBuyReverts(alice, t, 50 ether);
        assertFalse(arcade.unlocked(address(t), alice));
        uint256 got = _unlock(alice, t);
        assertGe(got, 50, "solved with a good score");
        assertTrue(arcade.unlocked(address(t), alice));
        vm.prank(alice);
        pad.buy{value: 50 ether}(address(t), 0);
        assertGt(t.balanceOf(alice), SUPPLY / 1_000);
        // a later bad run doesn't lock again
        vm.prank(alice);
        scores.startRun(address(t));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        scores.submitRun(address(t), hex"00");
        assertTrue(arcade.unlocked(address(t), alice));
        // a score below the threshold doesn't unlock (threshold 99 needs a 1-press solve)
    }

    function test_lowScoreDoesNotUnlock_creatorExempt() public {
        // the creator is capped like everyone unless the launch exempts them
        HookTokenV2 t0 = _launch(_one(arcadeId), _oneCfg(_cfg(address(lo), 95, 10, false)), 0);
        _curveBuyReverts(creator, t0, 50 ether);
        HookTokenV2 t = _launch(_one(arcadeId), _oneCfg(_cfgEx(address(lo), 95, 10, false)), 0);
        vm.prank(bob);
        bytes32 seed = scores.startRun(address(t));
        vm.roll(vm.getBlockNumber() + 1);
        bytes memory sol = _loSolution(seed);
        assertGt(sol.length, 5, "this seed's solution scores under 95");
        vm.prank(bob);
        scores.submitRun(address(t), sol);
        assertFalse(arcade.unlocked(address(t), bob));
        _curveBuyReverts(bob, t, 50 ether);
        // exemptCreator: the creator may hold more
        vm.prank(creator);
        pad.buy{value: 50 ether}(address(t), 0);
        assertGt(t.balanceOf(creator), SUPPLY / 1_000);
    }

    // pool phase: router and direct PoolManager buys are capped; sells and sends are not; transfers in are
    function test_poolPhaseRouterAggTransfers() public {
        HookTokenV2 t = _launch(_one(arcadeId), _oneCfg(_cfgEx(address(lo), 50, 100, false)), 0);
        PoolKey memory key = _graduateCapped(t, SUPPLY / 100 - 1 ether, 0);
        _buyReverts(alice, t, 500 ether);
        uint256 got = _routerBuy(alice, t, 1 ether);
        assertLe(t.balanceOf(alice), SUPPLY / 100);
        // the aggregator holds tokens mid-route: counts as a wallet
        vm.expectRevert();
        agg.swap(key, true, -int256(500 ether));
        // transfer into a capped wallet that would exceed: refused; to the creator: fine
        address h0 = _holder(0);
        uint256 hb = t.balanceOf(h0);
        vm.prank(h0);
        vm.expectRevert();
        t.transfer(alice, hb);
        vm.prank(h0);
        t.transfer(creator, hb);
        // sells untouched
        _routerSell(alice, t, got);
        // unlock alice: big buys and transfers in work
        _unlock(alice, t);
        _routerBuy(alice, t, 500 ether);
        assertGt(t.balanceOf(alice), SUPPLY / 100);
    }

    function test_untilGraduationLiftsCap() public {
        HookTokenV2 t = _launch(_one(arcadeId), _oneCfg(_cfg(address(lo), 50, 100, true)), 0);
        _curveBuyReverts(alice, t, 500 ether);
        _graduateCapped(t, SUPPLY / 100 - 1 ether, 0);
        (,, bool active) = arcade.ruleOf(address(t));
        assertFalse(active);
        _routerBuy(alice, t, 500 ether);
        assertGt(t.balanceOf(alice), SUPPLY / 100);
    }

    function testFuzz_capHoldsForLockedWallets(uint96 amt) public {
        HookTokenV2 t = _launch(_one(arcadeId), _oneCfg(_cfg(address(lo), 50, 10, false)), 0);
        uint256 a = bound(uint256(amt), 0.001 ether, 100 ether);
        vm.prank(carol);
        try pad.buy{value: a}(address(t), 0) {} catch {}
        assertLe(t.balanceOf(carol), SUPPLY / 1_000);
    }
}
