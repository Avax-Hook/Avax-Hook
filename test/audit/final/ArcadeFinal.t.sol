// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LightsOutGame} from "../../../contracts/v2/arcade/LightsOutGame.sol";
import {Game2048} from "../../../contracts/v2/arcade/Game2048.sol";
import {ArcadeScores} from "../../../contracts/v2/arcade/ArcadeScores.sol";
import {ArcadeModule} from "../../../contracts/v2/modules/ArcadeModule.sol";

contract ArcadeFinalHookStub {
    function poolManager() external pure returns (address) {
        return address(0xBEEF);
    }
}

contract ArcadeFinalBumper {
    function bump(ArcadeScores s, address token) external {
        s.startRun(token);
    }
}

/// Grinds Lights Out seeds for ONE wallet inside ONE block: it never calls startRun for itself until the seed it
/// would get is easy; other addresses' startRuns bump the global nonce and re-roll its next seed.
contract ArcadeFinalGrinder {
    ArcadeFinalBumper[] public bumpers;

    function make(uint256 n) external {
        for (uint256 i; i < n; ++i) bumpers.push(new ArcadeFinalBumper());
    }

    function grind(ArcadeScores s, address token, address bumpToken, uint256 maxPresses)
        external
        returns (bytes32 seed, uint256 n, uint256 bumps)
    {
        for (uint256 i; i <= bumpers.length; ++i) {
            bytes32 next = keccak256(abi.encode(blockhash(block.number - 1), address(this), token, s.nonces(token, address(this))));
            n = _pop(uint256(next) & ((1 << 25) - 1));
            if (n > 0 && n <= maxPresses) {
                seed = s.startRun(token);
                require(seed == next, "prediction");
                return (seed, n, i);
            }
            bumpers[i].bump(s, bumpToken);
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

contract ArcadeFinalTest is Test {
    LightsOutGame lo;
    Game2048 g2048;
    ArcadeScores scores;
    address safe = makeAddr("safe");
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
        scores.bind(tokenB, address(lo));
        vm.roll(100);
    }

    /// Regression: the seed counter is per player and token, so other addresses' startRuns no longer re-roll a
    /// player's next seed inside one block; the grinder never finds an easier seed than its first one.
    function test_arcade_othersCannotRerollMySeed() public {
        ArcadeFinalGrinder gr = new ArcadeFinalGrinder();
        gr.make(50);
        vm.roll(vm.getBlockNumber() + 1);
        bytes32 first = keccak256(abi.encode(blockhash(vm.getBlockNumber() - 1), address(gr), tokenA, uint256(0)));
        uint256 n0 = _pop(uint256(first) & ((1 << 25) - 1));
        if (n0 > 0 && n0 <= 5) return; // this block's one seed happens to be easy: nothing to grind
        vm.expectRevert(); // runs out of bumpers: no bump changes the seed
        gr.grind(scores, tokenA, tokenB, 5);
        assertEq(scores.nonces(tokenA, address(gr)), 0);
    }

    /// Regression: thresholds above the practical ceilings are refused (2048: 8,000; Lights Out: 95).
    function test_arcade_unreachableUnlockScoresRefused() public {
        ArcadeFinalHookStub stub = new ArcadeFinalHookStub();
        ArcadeModule m = new ArcadeModule(address(stub), scores);
        m.validateConfig(abi.encode(ArcadeModule.Config(address(g2048), 8_000, 10, false, false)));
        vm.expectRevert();
        m.validateConfig(abi.encode(ArcadeModule.Config(address(g2048), 15_000, 10, false, false)));
        vm.expectRevert();
        m.validateConfig(abi.encode(ArcadeModule.Config(address(lo), 96, 10, false, false)));
        assertEq(g2048.maxScore(), 8_000);
        assertEq(lo.maxScore(), 95);
    }

    function _pop(uint256 x) internal pure returns (uint256 c) {
        for (; x != 0; x &= x - 1) ++c;
    }
}
