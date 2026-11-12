// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IArcadeGame} from "./IArcadeGame.sol";

/// @title ArcadeScores
/// @notice On-chain arcade for launched tokens: each token is bound (once, at launch, by an approved binder such as
///         ArcadeModule) to one game from a Safe-owned allowlist; anyone can play it and the best score per wallet
///         and token is kept forever (it never goes down).
///
///   A run: `startRun(token)` fixes a seed = keccak256(blockhash(block.number - 1), player, token, n) and the
///   start block. The player plays off-chain (the widget runs the same pure game code) and sends every input in
///   one `submitRun(token, inputs)` (one byte per input) in a LATER block, within RUN_TTL. The contract replays the
///   game from the seed and keeps the score if it beats the player's best. One open run per player and token:
///   starting a new run abandons the open one; at most one start per player, token and block.
///
///   Honest limits: the seed is public as soon as `startRun` lands, so a solver bot can play perfectly, and
///   restarting rerolls the seed (once per block; a patient bot can still wait for an easy Lights Out start).
///   Scores prove someone played the inputs, not that a human did. The cap this unlocks is a game, not a
///   protection.
///   Gas: a replay is a loop of pure `step` calls, at most min(game.maxInputs(), MAX_INPUTS) of them; see the
///   tests for measured costs of a maximal run.
///
///   Owner (the Safe, two-step): `setGame` allow-lists games for NEW bindings and `setBinder` approves binder
///   contracts. Neither can touch a token already bound: its game stays playable forever (games are pure and
///   immutable), so nobody can freeze an unlock path.
contract ArcadeScores is Ownable2Step {
    struct Run {
        bytes32 seed;
        uint64 startBlock;
        uint64 startedAt;
    }

    struct Top {
        address player;
        uint96 score;
    }

    /// @notice Hard cap on inputs per run, whatever the game says.
    uint256 public constant MAX_INPUTS = 4_096;
    /// @notice A started run must be submitted within this many seconds.
    uint256 public constant RUN_TTL = 1 days;

    mapping(address game => bool) public allowedGame;
    mapping(address binder => bool) public isBinder;
    mapping(address token => address) public gameOf;
    mapping(address token => mapping(address player => uint256)) public best;
    mapping(address token => mapping(address player => Run)) internal _runs;
    mapping(address token => Top) public topOf;
    mapping(address token => uint256) public runsOf;
    /// @notice Runs a player has started on a token (the seed's counter). Per player and token, so nobody else's
    ///         starts can reroll a player's next seed inside one block.
    mapping(address token => mapping(address player => uint256)) public nonces;

    event GameSet(address indexed game, bool allowed);
    event BinderSet(address indexed binder, bool allowed);
    event Bound(address indexed token, address indexed game);
    event RunStarted(address indexed token, address indexed player, bytes32 seed, uint256 startBlock);
    event RunSubmitted(address indexed token, address indexed player, uint256 score, uint256 inputs, bool newBest);
    event NewTop(address indexed token, address indexed player, uint256 score);

    error NotBinder();
    error GameNotAllowed();
    error AlreadyBound();
    error NotBound();
    error NoRun();
    error SameBlock();
    error RunExpired();
    error TooManyInputs();
    error BadGame();

    constructor(address owner_) Ownable(owner_) {}

    // ---------------------------------------------------------------- owner

    function setGame(address game, bool allowed) external onlyOwner {
        if (allowed) {
            // sanity: a game must answer its interface
            uint256 m = IArcadeGame(game).maxInputs();
            if (m == 0 || IArcadeGame(game).maxScore() == 0) revert BadGame();
        }
        allowedGame[game] = allowed;
        emit GameSet(game, allowed);
    }

    function setBinder(address binder, bool allowed) external onlyOwner {
        isBinder[binder] = allowed;
        emit BinderSet(binder, allowed);
    }

    // ---------------------------------------------------------------- binding

    /// @notice Binds `token` to `game` for good (binders only; once per token).
    function bind(address token, address game) external {
        if (!isBinder[msg.sender]) revert NotBinder();
        if (!allowedGame[game]) revert GameNotAllowed();
        if (gameOf[token] != address(0)) revert AlreadyBound();
        gameOf[token] = game;
        emit Bound(token, game);
    }

    // ---------------------------------------------------------------- play

    /// @notice Starts a run (abandoning any open one) and returns its seed.
    function startRun(address token) external returns (bytes32 seed) {
        if (gameOf[token] == address(0)) revert NotBound();
        // one seed per wallet, token and block: grinding seeds in a loop costs a block per try
        if (_runs[token][msg.sender].startBlock == block.number) revert SameBlock();
        seed = keccak256(abi.encode(blockhash(block.number - 1), msg.sender, token, nonces[token][msg.sender]++));
        _runs[token][msg.sender] = Run(seed, uint64(block.number), uint64(block.timestamp));
        emit RunStarted(token, msg.sender, seed, block.number);
    }

    /// @notice Replays the open run with `inputs` (one byte each) and keeps the score if it is the player's best.
    function submitRun(address token, bytes calldata inputs) external returns (uint256 result) {
        Run memory r = _runs[token][msg.sender];
        if (r.startBlock == 0) revert NoRun();
        if (block.number <= r.startBlock) revert SameBlock();
        if (block.timestamp > uint256(r.startedAt) + RUN_TTL) revert RunExpired();
        delete _runs[token][msg.sender];

        IArcadeGame g = IArcadeGame(gameOf[token]);
        uint256 cap = g.maxInputs();
        if (cap > MAX_INPUTS) cap = MAX_INPUTS;
        if (inputs.length > cap) revert TooManyInputs();

        result = _replay(g, r.seed, inputs);
        unchecked {
            ++runsOf[token];
        }
        bool better = result > best[token][msg.sender];
        if (better) {
            best[token][msg.sender] = result;
            Top memory t = topOf[token];
            if (result > t.score) {
                topOf[token] = Top(msg.sender, uint96(result));
                emit NewTop(token, msg.sender, result);
            }
        }
        emit RunSubmitted(token, msg.sender, result, inputs.length, better);
    }

    // ---------------------------------------------------------------- views

    function runOf(address token, address player) external view returns (Run memory) {
        return _runs[token][player];
    }

    /// @notice What `inputs` would score from `seed` on `token`'s game (dry run for the widget).
    function preview(address token, bytes32 seed, bytes calldata inputs) external view returns (uint256) {
        IArcadeGame g = IArcadeGame(gameOf[token]);
        if (address(g) == address(0)) revert NotBound();
        return _replay(g, seed, inputs);
    }

    function _replay(IArcadeGame g, bytes32 seed, bytes calldata inputs) internal view returns (uint256) {
        uint256 state = g.init(seed);
        bool over;
        for (uint256 i; i < inputs.length && !over; ++i) {
            (state, over) = g.step(state, uint8(inputs[i]), seed, i);
        }
        return g.score(state);
    }
}
