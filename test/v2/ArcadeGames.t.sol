// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {LightsOutGame} from "../../contracts/v2/arcade/LightsOutGame.sol";
import {Game2048} from "../../contracts/v2/arcade/Game2048.sol";
import {ArcadeScores} from "../../contracts/v2/arcade/ArcadeScores.sol";

/// Pure game logic and ArcadeScores runs (no fork needed).
contract ArcadeGamesTest is Test {
    LightsOutGame lo;
    Game2048 g2048;
    ArcadeScores scores;
    address safe = makeAddr("safe");
    address alice = makeAddr("alice");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");

    function setUp() public {
        lo = new LightsOutGame();
        g2048 = new Game2048();
        scores = new ArcadeScores(safe);
        vm.startPrank(safe);
        scores.setGame(address(lo), true);
        scores.setGame(address(g2048), true);
        scores.setBinder(address(this), true);
        vm.stopPrank();
        scores.bind(tokenA, address(lo));
        scores.bind(tokenB, address(g2048));
        vm.roll(100);
    }

    // ---------------------------------------------------------------- Lights Out

    /// Pressing the seed's own press set again solves the board (presses commute and are self-inverse).
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

    function _play(address game, bytes32 seed, bytes memory inputs) internal view returns (uint256 state, bool over, uint256 used) {
        state = LightsOutGame(game).init(seed);
        for (uint256 i; i < inputs.length && !over; ++i) {
            (state, over) = LightsOutGame(game).step(state, uint8(inputs[i]), seed, i);
            used = i + 1;
        }
    }

    function test_lightsOut_pressTogglesNeighbours() public view {
        (uint256 s,) = lo.step(0, 12, 0, 0);
        (uint256 board, uint256 moves) = lo.decode(s);
        assertEq(board, (1 << 12) | (1 << 7) | (1 << 17) | (1 << 11) | (1 << 13));
        assertEq(moves, 1);
        (s,) = lo.step(0, 0, 0, 0); // corner: only 3 cells
        (board,) = lo.decode(s);
        assertEq(board, 1 | 2 | (1 << 5));
        (s,) = lo.step(0, 4, 0, 0); // top-right corner doesn't wrap to the next row
        (board,) = lo.decode(s);
        assertEq(board, (1 << 4) | (1 << 3) | (1 << 9));
    }

    function test_lightsOut_solveScores() public view {
        bytes32 seed = keccak256("seed");
        bytes memory sol = _loSolution(seed);
        (uint256 s, bool over, uint256 used) = _play(address(lo), seed, sol);
        assertTrue(over, "solved");
        assertEq(used, sol.length);
        assertEq(lo.score(s), 100 - sol.length);
    }

    function test_lightsOut_unsolvedScoresZero_andMaxMovesEnds() public view {
        bytes32 seed = keccak256("seed");
        uint256 s = lo.init(seed);
        assertGt(s, 0, "never starts solved");
        assertEq(lo.score(s), 0);
        bool over;
        // press cell 0 a hundred times: toggles back and forth, never solves (start isn't the 0-mask)
        for (uint256 i; i < 100; ++i) {
            assertFalse(over);
            (s, over) = lo.step(s, 0, seed, i);
        }
        assertTrue(over, "max moves");
        assertEq(lo.score(s), 0);
    }

    function test_lightsOut_zeroPatternStartsWithCentre() public view {
        assertEq(lo.init(bytes32(0)), (1 << 12) | (1 << 7) | (1 << 17) | (1 << 11) | (1 << 13));
    }

    function test_lightsOut_badInputReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LightsOutGame.BadInput.selector, uint8(25)));
        lo.step(0, 25, 0, 0);
    }

    function testFuzz_lightsOut_alwaysSolvable(bytes32 seed) public view {
        bytes memory sol = _loSolution(seed);
        if (sol.length == 0) return; // the centre-press fallback; covered above
        (uint256 s, bool over,) = _play(address(lo), seed, sol);
        // the press set may contain a null-space pattern and solve early; either way it ends solved
        assertTrue(over);
        assertGt(lo.score(s), 0);
    }

    // ---------------------------------------------------------------- 2048

    function _board(uint8[16] memory cells) internal pure returns (uint256 b) {
        for (uint256 k; k < 16; ++k) {
            b |= uint256(cells[k]) << (4 * k);
        }
    }

    function _countNew(uint8[16] memory after_, uint8[16] memory expect) internal pure returns (uint256 n, uint256 at) {
        for (uint256 k; k < 16; ++k) {
            if (after_[k] != expect[k]) {
                assertEq(expect[k], 0, "only an empty cell changes");
                assertTrue(after_[k] == 1 || after_[k] == 2, "spawn is a 2 or a 4");
                ++n;
                at = k;
            }
        }
    }

    function test_2048_slideLeftMergesOncePerTile() public view {
        uint8[16] memory c;
        (c[0], c[1], c[2]) = (1, 1, 2); // row 0: 2 2 4 _
        (c[4], c[5], c[6], c[7]) = (1, 1, 1, 1); // row 1: 2 2 2 2
        (uint256 s,) = g2048.step(_board(c), 0, bytes32("x"), 0);
        (uint8[16] memory got, uint256 pts, uint256 moves) = g2048.decode(s);
        uint8[16] memory want;
        (want[0], want[1]) = (2, 2); // 4 4 _ _ (the new 4 does not merge again)
        (want[4], want[5]) = (2, 2); // 4 4 _ _
        (uint256 n,) = _countNew(got, want);
        assertEq(n, 1, "one new tile");
        assertEq(pts, 4 + 4 + 4, "sum of merges");
        assertEq(moves, 1);
    }

    function test_2048_otherDirections() public view {
        uint8[16] memory c;
        (c[0], c[3]) = (3, 3); // row 0: 8 _ _ 8
        // right: _ _ _ 16
        (uint256 s,) = g2048.step(_board(c), 1, bytes32("x"), 0);
        (uint8[16] memory got, uint256 pts,) = g2048.decode(s);
        uint8[16] memory want;
        want[3] = 4;
        _countNew(got, want);
        assertEq(pts, 16);
        // up / down on a column
        uint8[16] memory d;
        (d[1], d[13]) = (2, 2); // column 1, rows 0 and 3
        (s,) = g2048.step(_board(d), 3, bytes32("x"), 0);
        (got, pts,) = g2048.decode(s);
        uint8[16] memory w2;
        w2[13] = 3;
        _countNew(got, w2);
        assertEq(pts, 8);
        (s,) = g2048.step(_board(d), 2, bytes32("x"), 0);
        (got,,) = g2048.decode(s);
        uint8[16] memory w3;
        w3[1] = 3;
        _countNew(got, w3);
    }

    function test_2048_noOpMoveSpawnsNothing() public view {
        uint8[16] memory c;
        (c[0], c[4]) = (1, 2); // left column, nothing slides left
        uint256 b = _board(c);
        (uint256 s, bool over) = g2048.step(b, 0, bytes32("x"), 0);
        assertEq(s & ((1 << 64) - 1), b, "board unchanged");
        assertFalse(over);
        assertEq(g2048.score(s), 0);
    }

    /// A no-op move spawns nothing and doesn't use up a random draw: the next real move spawns the same tile.
    function test_2048_noOpDoesNotSkipSpawnDraw() public view {
        uint8[16] memory c;
        (c[0], c[4]) = (1, 2); // left is a no-op, right is not
        uint256 b = _board(c);
        bytes32 seed = keccak256("draw");
        (uint256 direct,) = g2048.step(b, 1, seed, 0);
        (uint256 s,) = g2048.step(b, 0, seed, 0); // no-op
        (s,) = g2048.step(s, 0, seed, 1); // no-op
        (s,) = g2048.step(s, 1, seed, 2);
        assertEq(s & ((1 << 64) - 1), direct & ((1 << 64) - 1), "same spawn");
    }

    function test_2048_overWhenStuck() public view {
        uint8[16] memory c;
        for (uint256 k; k < 16; ++k) {
            c[k] = uint8(((k / 4) + (k % 4)) % 2 == 0 ? 1 : 2); // checkerboard: no move left
        }
        (, bool over) = g2048.step(_board(c), 0, bytes32("x"), 0);
        assertTrue(over);
    }

    function test_2048_initHasTwoTiles_andBadInput() public {
        (uint8[16] memory got,,) = g2048.decode(g2048.init(keccak256("s")));
        uint256 n;
        for (uint256 k; k < 16; ++k) {
            if (got[k] != 0) ++n;
        }
        assertEq(n, 2);
        vm.expectRevert(abi.encodeWithSelector(Game2048.BadInput.selector, uint8(4)));
        g2048.step(0, 4, 0, 0);
    }

    function testFuzz_2048_scoreNeverDrops(bytes32 seed, bytes memory inputs) public view {
        uint256 s = g2048.init(seed);
        bool over;
        uint256 last;
        for (uint256 i; i < inputs.length && i < 300 && !over; ++i) {
            (s, over) = g2048.step(s, uint8(inputs[i]) % 4, seed, i);
            uint256 sc = g2048.score(s);
            assertGe(sc, last);
            last = sc;
        }
    }

    // ---------------------------------------------------------------- ArcadeScores

    function test_scores_runAndBest() public {
        vm.prank(alice);
        bytes32 seed = scores.startRun(tokenA);
        bytes memory sol = _loSolution(seed);
        vm.prank(alice);
        vm.expectRevert(ArcadeScores.SameBlock.selector);
        scores.submitRun(tokenA, sol);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 got = scores.submitRun(tokenA, sol);
        assertGt(got, 0);
        assertEq(scores.best(tokenA, alice), got);
        (address top, uint96 topScore) = scores.topOf(tokenA);
        assertEq(top, alice);
        assertEq(topScore, got);
        // the run is closed
        vm.prank(alice);
        vm.expectRevert(ArcadeScores.NoRun.selector);
        scores.submitRun(tokenA, sol);
        // a worse run never lowers the best
        vm.prank(alice);
        scores.startRun(tokenA);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        assertEq(scores.submitRun(tokenA, hex"00"), 0);
        assertEq(scores.best(tokenA, alice), got);
        assertEq(scores.runsOf(tokenA), 2);
    }

    function test_scores_expiryLimitsAndAbandon() public {
        vm.prank(alice);
        bytes32 s1 = scores.startRun(tokenA);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        bytes32 s2 = scores.startRun(tokenA); // abandons the first run
        // at most one start per block (seed grinding costs a block per try)
        vm.prank(alice);
        vm.expectRevert(ArcadeScores.SameBlock.selector);
        scores.startRun(tokenA);
        assertTrue(s1 != s2);
        assertEq(scores.runOf(tokenA, alice).seed, s2);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert(ArcadeScores.RunExpired.selector);
        scores.submitRun(tokenA, hex"00");
        // too many inputs (Lights Out: 100)
        vm.prank(alice);
        scores.startRun(tokenA);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        vm.expectRevert(ArcadeScores.TooManyInputs.selector);
        scores.submitRun(tokenA, new bytes(101));
        // an unbound token can't be played
        vm.expectRevert(ArcadeScores.NotBound.selector);
        scores.startRun(makeAddr("nobody"));
    }

    function test_scores_ownerAndBinder() public {
        vm.expectRevert();
        scores.setGame(address(lo), false);
        vm.prank(alice);
        vm.expectRevert(ArcadeScores.NotBinder.selector);
        scores.bind(makeAddr("t"), address(lo));
        vm.expectRevert(ArcadeScores.AlreadyBound.selector);
        scores.bind(tokenA, address(lo));
        vm.expectRevert(ArcadeScores.GameNotAllowed.selector);
        scores.bind(makeAddr("t"), address(0xBEEF));
        // de-listing a game blocks new binds, never existing tokens
        vm.prank(safe);
        scores.setGame(address(lo), false);
        vm.expectRevert(ArcadeScores.GameNotAllowed.selector);
        scores.bind(makeAddr("t"), address(lo));
        vm.prank(alice);
        scores.startRun(tokenA);
        // two-step ownership
        address next = makeAddr("next");
        vm.prank(safe);
        scores.transferOwnership(next);
        assertEq(scores.owner(), safe);
        vm.prank(next);
        scores.acceptOwnership();
        assertEq(scores.owner(), next);
    }

    // ---------------------------------------------------------------- gas of maximal runs

    function test_gas_maxRuns() public {
        // Lights Out: 100 presses that never solve (cell 0 over and over)
        vm.prank(alice);
        scores.startRun(tokenA);
        vm.roll(vm.getBlockNumber() + 1);
        bytes memory lin = new bytes(100);
        uint256 g0 = gasleft();
        vm.prank(alice);
        scores.submitRun(tokenA, lin);
        uint256 loGas = g0 - gasleft();
        console2.log("LightsOut 100-input run gas", loGas);

        // 2048: maxInputs (500) inputs that keep the game alive: cycle left/up/right/up... and measure until it ends;
        // then a run of pure no-op moves (never ends, every step a full slide + check)
        vm.prank(alice);
        bytes32 seed = scores.startRun(tokenB);
        vm.roll(vm.getBlockNumber() + 1);
        bytes memory cyc = new bytes(g2048.maxInputs());
        for (uint256 i; i < cyc.length; ++i) {
            cyc[i] = bytes1(uint8([0, 2, 1, 2][i % 4]));
        }
        uint256 len = _aliveLen(seed, cyc);
        g0 = gasleft();
        vm.prank(alice);
        scores.submitRun(tokenB, cyc);
        uint256 cycGas = g0 - gasleft();
        console2.log("2048 cycling run: moves until over", len);
        console2.log("2048 cycling run gas", cycGas);

        vm.prank(alice);
        seed = scores.startRun(tokenB);
        vm.roll(vm.getBlockNumber() + 1);
        // first move left, then the rest lefts: after the board settles left most are no-ops (each still a
        // full step); spawns happen whenever a left changes something
        bytes memory lefts = new bytes(g2048.maxInputs());
        len = _aliveLen(seed, lefts);
        g0 = gasleft();
        vm.prank(alice);
        scores.submitRun(tokenB, lefts);
        uint256 leftGas = g0 - gasleft();
        console2.log("2048 all-left run: moves until over", len);
        console2.log("2048 all-left run gas", leftGas);
        assertLt(loGas, 1_000_000);
        assertLt(leftGas, 8_000_000);
        assertLt(cycGas, 8_000_000);
    }

    function _aliveLen(bytes32 seed, bytes memory inputs) internal view returns (uint256 used) {
        uint256 s = g2048.init(seed);
        bool over;
        for (uint256 i; i < inputs.length && !over; ++i) {
            (s, over) = g2048.step(s, uint8(inputs[i]), seed, i);
            used = i + 1;
        }
    }
}
