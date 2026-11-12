// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IArcadeGame} from "./IArcadeGame.sol";

/// @title Game2048
/// @notice 4×4 2048. Each move slides every tile as far as it goes in one direction; two equal tiles that meet merge
///         into one of the next power of two (once per tile per move). After every move that changed the board a
///         new tile appears on an empty cell: a 2 (90%) or a 4 (10%).
///   - Input: 0 = left, 1 = right, 2 = up, 3 = down. Anything else reverts. A move that changes nothing is
///     allowed and spawns nothing (it only uses up one input).
///   - Randomness: the n-th new tile's cell and value come from keccak256(seed, n), n = tiles spawned so far
///     (so a no-op move can't be used to skip to a friendlier draw); the two starting tiles from
///     keccak256(seed, "init", 0/1). Fully deterministic given the seed.
///   - Score: the classic 2048 score, the SUM OF MERGES (every merge adds the value of the tile it creates).
///     Chosen over "max tile" because it grows smoothly and rewards long, efficient runs.
///   - End: no empty cell and no two equal neighbours, or MAX_MOVES inputs used.
///   Tiles are 4-bit exponents (1 = 2, 2 = 4, … 15 = 32768); two 32768 tiles never merge (unreachable in
///   MAX_MOVES anyway). State layout: bits 0..63 the board (cell k = row * 4 + col at bits 4k..4k+3),
///   bits 64..127 the score, bits 128..159 the move count, bits 160..191 the spawn count.
contract Game2048 is IArcadeGame {
    uint256 public constant MAX_MOVES = 500; // keeps a full replay under ~7M gas (see tests)
    uint256 internal constant BOARD_MASK = (1 << 64) - 1;

    uint256 internal constant MAX_SCORE = 8_000;

    error BadInput(uint8 input);

    function name() external pure returns (string memory) {
        return "2048";
    }

    function maxInputs() external pure returns (uint256) {
        return MAX_MOVES;
    }

    /// @notice Highest unlock score a token may require: 8,000.
    /// @dev Not the theoretical maximum. score = Σ k·2^k over the final tiles − 2·(spawned 2s) − 8·(spawned 4s) with at
    ///      most 502 spawns, so no run can pass ~14,248 (and only if every spawn were a 4, odds 0.1^502); with the
    ///      real 9:1 spawn mix the ceiling is ~9.5k and a strong expectimax bot scores 7.3k–9.3k. 8,000 keeps
    ///      every allowed threshold reachable by strong play.
    function maxScore() external pure returns (uint256) {
        return MAX_SCORE;
    }

    function init(bytes32 seed) external pure returns (uint256 state) {
        uint256 board = _spawn(0, uint256(keccak256(abi.encode(seed, "init", uint256(0)))));
        board = _spawn(board, uint256(keccak256(abi.encode(seed, "init", uint256(1)))));
        return board;
    }

    function step(uint256 state, uint8 input, bytes32 seed, uint256) external pure returns (uint256 next, bool over) {
        if (input > 3) revert BadInput(input);
        uint256 board = state & BOARD_MASK;
        uint256 pts = (state >> 64) & type(uint64).max;
        uint256 moves = ((state >> 128) & type(uint32).max) + 1;
        uint256 spawns = (state >> 160) & type(uint32).max;
        (uint256 moved, uint256 gained) = _move(board, input);
        if (moved != board) {
            moved = _spawn(moved, uint256(keccak256(abi.encode(seed, spawns))));
            ++spawns;
            pts += gained;
        }
        next = moved | (pts << 64) | (moves << 128) | (spawns << 160);
        over = moves >= MAX_MOVES || !_canMove(moved);
    }

    function score(uint256 state) external pure returns (uint256) {
        return (state >> 64) & type(uint64).max;
    }

    /// @notice Board exponents (cell k = row * 4 + col; 0 = empty), score and move count, for the widget.
    function decode(uint256 state) external pure returns (uint8[16] memory cells, uint256 pts, uint256 moves) {
        for (uint256 k; k < 16; ++k) {
            cells[k] = uint8((state >> (4 * k)) & 0xf);
        }
        pts = (state >> 64) & type(uint64).max;
        moves = (state >> 128) & type(uint32).max;
    }

    // ---------------------------------------------------------------- internals
    // Bit tricks keep a move at a few thousand gas: rows are 16-bit lanes (cell 0 of a row in the low nibble),
    // right/down reverse the lanes, up/down transpose the board first.

    function _move(uint256 board, uint256 dir) internal pure returns (uint256 out, uint256 gained) {
        uint256 b = dir >= 2 ? _transpose(board) : board;
        bool rev = dir == 1 || dir == 3;
        for (uint256 j; j < 4; ++j) {
            uint256 l = (b >> (16 * j)) & 0xffff;
            if (rev) l = _rev(l);
            (uint256 nl, uint256 g) = _slide(l);
            if (rev) nl = _rev(nl);
            out |= nl << (16 * j);
            gained += g;
        }
        if (dir >= 2) out = _transpose(out);
    }

    /// @dev Slides one 4-cell lane towards its low nibble, merging equal neighbours once.
    function _slide(uint256 l) internal pure returns (uint256 out, uint256 gained) {
        if (l == 0) return (0, 0);
        // compress the non-empty cells
        uint256 packed;
        uint256 n;
        for (uint256 p; p < 4; ++p) {
            uint256 v = (l >> (4 * p)) & 0xf;
            if (v != 0) {
                packed |= v << (4 * n);
                ++n;
            }
        }
        uint256 w;
        for (uint256 k; k < n; ++k) {
            uint256 v = (packed >> (4 * k)) & 0xf;
            if (k + 1 < n && ((packed >> (4 * (k + 1))) & 0xf) == v && v < 15) {
                ++v;
                gained += 1 << v;
                ++k;
            }
            out |= v << (4 * w);
            ++w;
        }
    }

    function _rev(uint256 l) internal pure returns (uint256) {
        return ((l & 0xf) << 12) | ((l & 0xf0) << 4) | ((l >> 4) & 0xf0) | (l >> 12);
    }

    /// @dev Transposes the 4×4 nibble matrix (cell row * 4 + col <-> col * 4 + row).
    function _transpose(uint256 x) internal pure returns (uint256) {
        uint256 a1 = x & 0xF0F00F0FF0F00F0F;
        uint256 a2 = x & 0x0000F0F00000F0F0;
        uint256 a3 = x & 0x0F0F00000F0F0000;
        uint256 a = a1 | (a2 << 12) | (a3 >> 12);
        uint256 b1 = a & 0xFF00FF0000FF00FF;
        uint256 b2 = a & 0x00FF00FF00000000;
        uint256 b3 = a & 0x00000000FF00FF00;
        return b1 | (b2 >> 24) | (b3 << 24);
    }

    /// @dev One bit per non-empty cell, at the cell's low nibble bit.
    function _occupied(uint256 board) internal pure returns (uint256) {
        return (board | (board >> 1) | (board >> 2) | (board >> 3)) & 0x1111111111111111;
    }

    /// @dev Puts a 2 (90%) or a 4 (10%) on the (r % empties)-th empty cell. No-op on a full board.
    function _spawn(uint256 board, uint256 r) internal pure returns (uint256) {
        uint256 free = ~_occupied(board) & 0x1111111111111111;
        uint256 empties = _count(free);
        if (empties == 0) return board;
        uint256 pick = r % empties;
        uint256 v = (r >> 128) % 10 == 0 ? 2 : 1;
        for (uint256 k; k < 16; ++k) {
            if ((free >> (4 * k)) & 1 == 1) {
                if (pick == 0) return board | (v << (4 * k));
                --pick;
            }
        }
        return board;
    }

    /// @dev Number of set nibble-low bits in a 0x1111… mask.
    function _count(uint256 m) internal pure returns (uint256) {
        m = (m & 0x0F0F0F0F0F0F0F0F) + ((m >> 4) & 0x0F0F0F0F0F0F0F0F);
        m = (m * 0x0101010101010101) & type(uint64).max;
        return m >> 56;
    }

    function _canMove(uint256 board) internal pure returns (bool) {
        if (_occupied(board) != 0x1111111111111111) return true;
        return _pairInRows(board) || _pairInRows(_transpose(board));
    }

    function _pairInRows(uint256 b) internal pure returns (bool) {
        for (uint256 j; j < 4; ++j) {
            uint256 l = (b >> (16 * j)) & 0xffff;
            uint256 c0 = l & 0xf;
            uint256 c1 = (l >> 4) & 0xf;
            uint256 c2 = (l >> 8) & 0xf;
            uint256 c3 = l >> 12;
            if (c0 == c1 || c1 == c2 || c2 == c3) return true;
        }
        return false;
    }
}
