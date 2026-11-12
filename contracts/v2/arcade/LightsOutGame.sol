// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IArcadeGame} from "./IArcadeGame.sol";

/// @title LightsOutGame
/// @notice 5×5 Lights Out. Pressing a cell toggles it and its up/down/left/right neighbours; the goal is to turn
///         every light off in as few presses as possible.
///   - Input: the cell to press, 0..24 (row * 5 + column). Anything else reverts.
///   - Start: the seed's low 25 bits pick a set of cells and the game presses them on an all-off board, so every
///     start is reachable from (and therefore solvable back to) all-off. If those presses cancel out (4 of the 2^25
///     patterns do), the centre cell is pressed instead, so a run never starts solved.
///   - End: all lights off (solved), or MAX_MOVES presses made.
///   - Score: solved ? MAX_MOVES − moves : 0 (so 1..99; fewer presses score more).
///   State layout: bits 0..24 the board (bit = cell, 1 = on), bits 32..47 the press count.
contract LightsOutGame is IArcadeGame {
    uint256 public constant CELLS = 25;
    uint256 public constant MAX_MOVES = 100;
    uint256 internal constant BOARD_MASK = (1 << 25) - 1;

    error BadInput(uint8 input);

    function name() external pure returns (string memory) {
        return "Lights Out";
    }

    function maxInputs() external pure returns (uint256) {
        return MAX_MOVES;
    }

    /// @notice Highest unlock score a token may require: 95 (solved in 5 presses). Scores run 1..99, but a perfect
    ///         solver scores 85+ on every seed and 90 at the median; 97+ needs a rare seed (~1 in 600), so higher
    ///         thresholds would mostly test luck.
    function maxScore() external pure returns (uint256) {
        return 95;
    }

    function init(bytes32 seed) external pure returns (uint256 state) {
        uint256 presses = uint256(seed) & BOARD_MASK;
        uint256 board;
        for (uint256 c; c < CELLS; ++c) {
            if (presses & (1 << c) != 0) board ^= _mask(c);
        }
        if (board == 0) board = _mask(12);
        return board;
    }

    function step(uint256 state, uint8 input, bytes32, uint256) external pure returns (uint256 next, bool over) {
        if (input >= CELLS) revert BadInput(input);
        uint256 board = (state & BOARD_MASK) ^ _mask(input);
        uint256 moves = ((state >> 32) & 0xffff) + 1;
        next = board | (moves << 32);
        over = board == 0 || moves >= MAX_MOVES;
    }

    function score(uint256 state) external pure returns (uint256) {
        if (state & BOARD_MASK != 0) return 0;
        uint256 moves = (state >> 32) & 0xffff;
        return moves >= MAX_MOVES ? 0 : MAX_MOVES - moves;
    }

    /// @notice The board (25 bits) and the press count of a state, for the widget.
    function decode(uint256 state) external pure returns (uint256 board, uint256 moves) {
        return (state & BOARD_MASK, (state >> 32) & 0xffff);
    }

    /// @dev Cell `c` and its orthogonal neighbours.
    function _mask(uint256 c) internal pure returns (uint256 m) {
        uint256 r = c / 5;
        uint256 col = c % 5;
        m = 1 << c;
        if (r > 0) m |= 1 << (c - 5);
        if (r < 4) m |= 1 << (c + 5);
        if (col > 0) m |= 1 << (c - 1);
        if (col < 4) m |= 1 << (c + 1);
    }
}
