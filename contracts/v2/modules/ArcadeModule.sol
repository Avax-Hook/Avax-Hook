// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {ArcadeScores} from "../arcade/ArcadeScores.sol";
import {IArcadeGame} from "../arcade/IArcadeGame.sol";

/// @title ArcadeModule
/// @notice "Play to hold": a game lives inside the coin. Every wallet may hold at most `capBps` of the supply
///         (default 0.1%) until it scores at least `unlockScore` in the token's game on ArcadeScores; from then
///         on it has no cap. The unlock is permanent: ArcadeScores keeps each wallet's best score per token and
///         it never goes down.
///   - The game is picked at launch from the Safe's allowlist in ArcadeScores and bound to the token for good
///     (only this module may bind).
///   - Transfer rule like MaxPerWalletModule: checked on every token move into a wallet (curve buys, pool buys,
///     transfers), after balances update. Selling and sending are never limited through the AvaxHook router or the
///     curve. Exempt: the PoolManager, the launchpad, the hook, 0x…dEaD, this module, the pool's other modules (Auto-LP vault, pots), and the creator only when
///     the launch sets `exemptCreator`. Aggregators holding tokens mid-route count as wallets: a route that pulls
///     more than the cap into an aggregator contract (buy or sell) can be refused, so sell through the AvaxHook
///     router or the curve.
///   - `untilGraduation`: the cap only applies on the bonding curve; once the pool opens there is no cap.
///   Honest limits: the cap is a game, not a protection. A solver bot plays perfectly once it sees the seed (and
///   can wait for an easy Lights Out start, one seed per block), and splitting across wallets gets around a
///   per-wallet cap.
contract ArcadeModule is HookModuleBase {
    struct Config {
        address game; // allow-listed in ArcadeScores
        uint32 unlockScore; // 1 .. game.maxScore()
        uint16 capBps; // of the 1B supply, 0.01% .. 50%
        bool untilGraduation; // no cap once the pool opens
        bool exemptCreator; // the creator may hold more than the cap (off by default, as MaxPerWallet)
    }

    struct Rule {
        Config cfg;
        address token;
        address creator;
        bool registered;
    }

    uint16 public constant MIN_CAP_BPS = 1;
    uint16 public constant MAX_CAP_BPS = 5_000;
    uint16 public constant DEFAULT_CAP_BPS = 10;

    ArcadeScores public immutable scores;

    mapping(PoolId => Rule) internal _rules;
    mapping(address token => PoolId) public poolOf;

    error CapExceeded(address wallet, uint256 balance, uint256 cap, uint256 bestScore, uint256 unlockScore);

    constructor(address _hook, ArcadeScores _scores) HookModuleBase(_hook) {
        scores = _scores;
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.ON_TRANSFER;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_HOLDING_CAP;
    }

    function validateConfig(bytes calldata config) public view override {
        Config memory c = abi.decode(config, (Config));
        if (c.capBps < MIN_CAP_BPS || c.capBps > MAX_CAP_BPS || c.unlockScore == 0) revert BadConfig();
        if (!scores.allowedGame(c.game)) revert BadConfig();
        if (c.unlockScore > IArcadeGame(c.game).maxScore()) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address creator, bytes calldata config)
        external
        override
        onlyHook
    {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        validateConfig(config);
        Config memory c = abi.decode(config, (Config));
        r.cfg = c;
        r.token = token;
        r.creator = creator;
        r.registered = true;
        poolOf[token] = id;
        scores.bind(token, c.game);
    }

    function onTransfer(PoolId id, address token, address, address, address to, uint256) external view override onlyHook {
        Rule storage r = _rules[id];
        if (to == address(poolManager) || to == ModuleCaps.BURN || to == hook || to == address(this)) return;
        if (to == r.creator && r.cfg.exemptCreator) return;
        if (to == IAvaxHookV2View(hook).launchpad()) return;
        if (r.cfg.untilGraduation && _openedAt(id) != 0) return;
        uint256 cap = (TOTAL_SUPPLY * r.cfg.capBps) / BPS;
        uint256 bal = IERC20(token).balanceOf(to);
        if (bal <= cap) return;
        uint256 b = scores.best(token, to);
        if (b >= r.cfg.unlockScore) return;
        if (PoolModules.isModule(hook, id, to)) return; // a module of this pool (Auto-LP vault, pot)
        revert CapExceeded(to, bal, cap, b, r.cfg.unlockScore);
    }

    // ---------------------------------------------------------------- views

    function ruleOf(address token) external view returns (Config memory cfg, uint256 cap, bool active) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        cfg = r.cfg;
        cap = (TOTAL_SUPPLY * r.cfg.capBps) / BPS;
        active = r.registered && !(r.cfg.untilGraduation && _openedAt(id) != 0);
    }

    /// @notice True once `wallet` has reached the unlock score (permanent).
    function unlocked(address token, address wallet) external view returns (bool) {
        Rule storage r = _rules[poolOf[token]];
        return r.registered && scores.best(token, wallet) >= r.cfg.unlockScore;
    }
}
