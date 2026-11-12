// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IArcadeGame
/// @notice A deterministic single-player game over a packed uint256 state. Every function is pure: the same
///         seed and the same inputs always give the same score, so ArcadeScores can replay a run on-chain from
///         its seed and the player's input bytes alone. Games hold no storage and no owner.
///
///   Replay (ArcadeScores.submitRun):
///     state = init(seed)
///     for i in 0 .. inputs.length-1:  (state, over) = step(state, inputs[i], seed, i); stop when over
///     result = score(state)
///   `step` reverts on an input outside the game's range (the whole submission then reverts).
interface IArcadeGame {
    /// @notice Short display name ("Lights Out", "2048").
    function name() external pure returns (string memory);

    /// @notice The most inputs one run may contain (ArcadeScores also caps this at 4096).
    function maxInputs() external pure returns (uint256);

    /// @notice The highest unlock score a token may require: a practical ceiling strong play reaches, not the
    ///         theoretical maximum, so a creator can't set a threshold nobody will ever meet.
    function maxScore() external pure returns (uint256);

    /// @notice The starting state for `seed`.
    function init(bytes32 seed) external pure returns (uint256 state);

    /// @notice Applies input number `i` (0-based) to `state`. `seed` and `i` feed any in-game randomness.
    /// @return next the new state
    /// @return over true when the run has ended (solved, or no move left); later inputs are ignored
    function step(uint256 state, uint8 input, bytes32 seed, uint256 i) external pure returns (uint256 next, bool over);

    /// @notice The score of a (final) state.
    function score(uint256 state) external pure returns (uint256);
}
