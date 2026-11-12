// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LightsOutGame} from "../../contracts/v2/arcade/LightsOutGame.sol";
import {Game2048} from "../../contracts/v2/arcade/Game2048.sol";
import {ArcadeScores} from "../../contracts/v2/arcade/ArcadeScores.sol";

contract G2048Harness is Game2048 {
    function move(uint256 b, uint256 d) external pure returns (uint256, uint256) {
        return _move(b, d);
    }

    function transpose(uint256 b) external pure returns (uint256) {
        return _transpose(b);
    }

    function canMove(uint256 b) external pure returns (bool) {
        return _canMove(b);
    }
}

/// Starts runs in a loop (one tx) until the seed's Lights Out press set is tiny, so the run scores >= 100 - maxPresses.
contract SeedGrinder {
    function grind(ArcadeScores s, address token, uint256 maxPresses, uint256 tries) external returns (bytes32 seed, uint256 n) {
        for (uint256 t; t < tries; ++t) {
            seed = s.startRun(token);
            n = _pop(uint256(seed) & ((1 << 25) - 1));
            if (n <= maxPresses && n > 0) return (seed, n);
        }
        revert("no luck");
    }

    function submit(ArcadeScores s, address token, bytes calldata inputs) external returns (uint256) {
        return s.submitRun(token, inputs);
    }

    function _pop(uint256 x) internal pure returns (uint256 c) {
        for (; x != 0; x &= x - 1) ++c;
    }
}

contract ArcadeAuditTest is Test {
    G2048Harness g;
    LightsOutGame lo;
    ArcadeScores scores;
    address safe = makeAddr("safe");
    address tokenA = makeAddr("tokenA");

    function setUp() public {
        g = new G2048Harness();
        lo = new LightsOutGame();
        scores = new ArcadeScores(safe);
        vm.startPrank(safe);
        scores.setGame(address(lo), true);
        scores.setBinder(address(this), true);
        vm.stopPrank();
        scores.bind(tokenA, address(lo));
        vm.roll(100);
    }

    // ---- reference 2048 (naive) ----
    function _cell(uint256 b, uint256 r, uint256 c) internal pure returns (uint256) {
        return (b >> (4 * (r * 4 + c))) & 0xf;
    }

    function _refMove(uint256 b, uint256 dir) internal pure returns (uint256 out, uint256 gained) {
        for (uint256 lane; lane < 4; ++lane) {
            uint256[4] memory v;
            for (uint256 k; k < 4; ++k) {
                (uint256 r, uint256 c) = _rc(lane, k, dir);
                v[k] = _cell(b, r, c);
            }
            uint256[4] memory comp;
            uint256 n;
            for (uint256 k; k < 4; ++k) if (v[k] != 0) comp[n++] = v[k];
            uint256[4] memory res;
            uint256 w;
            for (uint256 k; k < n; ++k) {
                if (k + 1 < n && comp[k] == comp[k + 1] && comp[k] < 15) {
                    res[w++] = comp[k] + 1;
                    gained += 1 << (comp[k] + 1);
                    ++k;
                } else {
                    res[w++] = comp[k];
                }
            }
            for (uint256 k; k < 4; ++k) {
                (uint256 r, uint256 c) = _rc(lane, k, dir);
                out |= res[k] << (4 * (r * 4 + c));
            }
        }
    }

    /// k-th cell of lane in the direction of travel (k = 0 is the wall it slides to)
    function _rc(uint256 lane, uint256 k, uint256 dir) internal pure returns (uint256 r, uint256 c) {
        if (dir == 0) return (lane, k); // left
        if (dir == 1) return (lane, 3 - k); // right
        if (dir == 2) return (k, lane); // up (row 0 is the top)
        return (3 - k, lane); // down
    }

    function testFuzz_audit_2048MoveMatchesReference(uint64 board, uint8 dir) public view {
        dir = dir % 4;
        (uint256 a, uint256 ga) = g.move(board, dir);
        (uint256 b, uint256 gb) = _refMove(board, dir);
        assertEq(a, b, "board");
        assertEq(ga, gb, "gain");
    }

    function testFuzz_audit_transposeInvolution(uint64 board) public view {
        uint256 t = g.transpose(board);
        assertEq(g.transpose(t), board);
        for (uint256 r; r < 4; ++r) {
            for (uint256 c; c < 4; ++c) {
                assertEq(_cell(t, r, c), _cell(board, c, r));
            }
        }
    }

    /// FIXED: one start per wallet, token and block, so looping startRun in one tx reverts (a grinder now pays
    /// a block per try).
    function test_audit_lightsOutSeedGrindingBlocked() public {
        SeedGrinder gr = new SeedGrinder();
        vm.expectRevert(ArcadeScores.SameBlock.selector);
        gr.grind(scores, tokenA, 0, 2);
    }

    /// Seed grinding is still possible across blocks (documented): it now costs one block per try.
    function test_audit_lightsOutSeedGrinding() public {
        SeedGrinder gr = new SeedGrinder();
        bytes32 seed;
        uint256 n;
        uint256 g0 = gasleft();
        for (uint256 t; t < 20_000; ++t) {
            vm.roll(vm.getBlockNumber() + 1);
            try gr.grind(scores, tokenA, 5, 1) returns (bytes32 s_, uint256 n_) {
                (seed, n) = (s_, n_);
                break;
            } catch {}
        }
        uint256 used = g0 - gasleft();
        emit log_named_uint("presses", n);
        emit log_named_uint("grind gas", used);
        uint256 presses = uint256(seed) & ((1 << 25) - 1);
        bytes memory inputs = new bytes(n);
        uint256 w;
        for (uint256 c; c < 25; ++c) {
            if (presses & (1 << c) != 0) inputs[w++] = bytes1(uint8(c));
        }
        vm.roll(vm.getBlockNumber() + 1);
        uint256 s = gr.submit(scores, tokenA, inputs);
        emit log_named_uint("score", s);
        assertGe(s, 95);
    }
}
