// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";

/// @title RisingMaxWalletModule
/// @notice A max-per-wallet cap that rises for everyone on a clock that starts at the launch:
///   - LINEAR:   cap = startBps + stepBps · n
///   - DOUBLING: cap = startBps · 2^n
///   with n = whole `interval`s since the launch. Once the cap reaches 100% of the supply there is no cap.
///   The schedule is bounded: it always reaches 100% within MAX_SCHEDULE (365 days) of the launch.
///   - Like MaxPerWalletModule: no wallet may end up holding more than the cap, whether it buys (curve or pool,
///     any route) or receives a transfer. Selling and sending are never limited. The PoolManager, the
///     launchpad, the hook, 0x…dEaD, this module and the pool's other modules (Auto-LP vault, pots) are exempt; the creator is not. Contracts holding tokens
///     mid-route (some aggregators) count as wallets. Splitting a bag across wallets gets around it.
///   - Claims bypass guard (2026-11-12): While there is a cap (until it reaches 100%), pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract RisingMaxWalletModule is HookModuleBase {
    struct Config {
        uint16 startBps; // cap at launch, of the 1B supply: 0.1% .. 50%
        uint8 mode; // 0 = linear (+stepBps per interval), 1 = doubling (x2 per interval)
        uint16 stepBps; // linear: added per interval, 0.01% .. 50%; doubling: must be 0
        uint32 interval; // seconds per step: 1 minute .. 7 days
    }

    struct Rule {
        Config cfg; // 9 bytes
        uint48 launchedAt;
        address token;
        bool registered;
    }

    uint8 public constant LINEAR = 0;
    uint8 public constant DOUBLING = 1;
    uint16 public constant MIN_START_BPS = 10;
    uint16 public constant MAX_START_BPS = 5_000;
    uint16 public constant MAX_STEP_BPS = 5_000;
    uint32 public constant MIN_INTERVAL = 60;
    uint32 public constant MAX_INTERVAL = 7 days;
    uint256 public constant MAX_SCHEDULE = 365 days;

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    error MaxWalletExceeded(address wallet, uint256 balance, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER;
    }

    /// @dev Claims bypass guard: while there is a cap, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy && _cap(_rules[ctx.poolId]) != 0) RouterOnlyGuard.check(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_HOLDING_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.startBps < MIN_START_BPS || c.startBps > MAX_START_BPS) revert BadConfig();
        if (c.interval < MIN_INTERVAL || c.interval > MAX_INTERVAL) revert BadConfig();
        if (_steps(c) * c.interval > MAX_SCHEDULE) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.launchedAt = uint48(block.timestamp);
        r.token = token;
        r.registered = true;
        poolOf[token] = id;
    }

    function onTransfer(PoolId id, address token, address, address, address to, uint256) external view override onlyHook {
        if (to == address(poolManager) || to == ModuleCaps.BURN || to == hook || to == address(this)) return;
        if (to == IAvaxHookV2View(hook).launchpad()) return;
        uint256 cap = _cap(_rules[id]);
        if (cap == 0) return;
        uint256 bal = IERC20(token).balanceOf(to);
        if (bal > cap && !PoolModules.isModule(hook, id, to)) revert MaxWalletExceeded(to, bal, cap);
    }

    // ---------------------------------------------------------------- views

    /// @return cap    the max per wallet now (0 = no cap any more)
    /// @return nextAt when it rises next (0 = no cap any more)
    /// @return freeAt when the cap is gone for good
    function currentCap(address token) external view returns (uint256 cap, uint256 nextAt, uint256 freeAt) {
        Rule storage r = _rules[poolOf[token]];
        if (!r.registered) return (0, 0, 0);
        Config memory c = r.cfg;
        freeAt = uint256(r.launchedAt) + _steps(c) * c.interval;
        cap = _cap(r);
        if (cap == 0) return (0, 0, freeAt);
        nextAt = uint256(r.launchedAt) + ((block.timestamp - r.launchedAt) / c.interval + 1) * c.interval;
    }

    /// @notice The cap at timestamp `t` (0 = no cap), for the UI chart.
    function capAt(address token, uint256 t) external view returns (uint256) {
        Rule storage r = _rules[poolOf[token]];
        if (!r.registered) return 0;
        return _capAtTime(r, t);
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    function _cap(Rule storage r) internal view returns (uint256) {
        return _capAtTime(r, block.timestamp);
    }

    function _capAtTime(Rule storage r, uint256 t) internal view returns (uint256) {
        Config memory c = r.cfg;
        uint256 n = t > r.launchedAt ? (t - r.launchedAt) / c.interval : 0;
        if (n >= _steps(c)) return 0;
        uint256 bps = c.mode == LINEAR ? c.startBps + n * c.stepBps : uint256(c.startBps) << n;
        return (TOTAL_SUPPLY * bps) / BPS;
    }

    /// @dev Whole intervals until the cap reaches 100% (reverts BadConfig on a bad mode/step).
    function _steps(Config memory c) internal pure returns (uint256 n) {
        if (c.mode == LINEAR) {
            if (c.stepBps == 0 || c.stepBps > MAX_STEP_BPS) revert BadConfig();
            return (BPS - c.startBps + c.stepBps - 1) / c.stepBps;
        }
        if (c.mode != DOUBLING || c.stepBps != 0) revert BadConfig();
        while ((uint256(c.startBps) << n) < BPS) ++n; // <= 10 rounds
    }
}
