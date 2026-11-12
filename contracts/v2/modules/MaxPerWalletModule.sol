// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";

/// @title MaxPerWalletModule
/// @notice Transfer rule: no wallet may end up holding more than `maxBps` of the supply, from launch (curve
///         buys included) until `duration` seconds after the pool opens (0 = forever). Selling and sending
///         are never limited; the PoolManager, the launchpad, the hook and 0x…dEaD are exempt, and the creator
///         too only when the launch sets `exemptCreator` (L-1: off by default, the UI says so when on).
///         Contracts that hold tokens mid-route (some aggregators) count as wallets.
///   - Claims bypass guard (2026-11-12): While the cap applies (`duration` after the pool opens, or forever), pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract MaxPerWalletModule is HookModuleBase {
    struct Config {
        uint16 maxBps; // of the 1B supply, 0.1% .. 50%
        uint32 duration; // seconds after the pool opens, 0 = forever
        bool exemptCreator; // the creator may hold more than the cap
    }

    struct Rule {
        Config cfg;
        address creator;
        bool registered;
    }

    uint16 public constant MIN_BPS = 10;
    uint16 public constant MAX_BPS = 5_000;
    uint32 public constant MAX_DURATION = 365 days;

    mapping(PoolId => Rule) internal _rules;

    error MaxWalletExceeded(address wallet, uint256 balance, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER;
    }

    /// @dev Claims bypass guard: while the cap applies, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy) {
            uint32 d = _rules[ctx.poolId].cfg.duration;
            uint256 opened = _openedAt(ctx.poolId);
            if (d == 0 || opened == 0 || block.timestamp < opened + d) RouterOnlyGuard.check(ctx);
        }
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_HOLDING_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.maxBps < MIN_BPS || c.maxBps > MAX_BPS || c.duration > MAX_DURATION) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address creator, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.creator = creator;
        r.registered = true;
    }

    function onTransfer(PoolId id, address token, address, address, address to, uint256) external view override onlyHook {
        Rule storage r = _rules[id];
        if (to == address(poolManager) || to == ModuleCaps.BURN || to == hook) return;
        if (to == r.creator && r.cfg.exemptCreator) return;
        if (to == IAvaxHookV2View(hook).launchpad()) return;
        if (r.cfg.duration != 0) {
            uint256 opened = _openedAt(id);
            if (opened != 0 && block.timestamp >= opened + r.cfg.duration) return;
        }
        uint256 cap = (TOTAL_SUPPLY * r.cfg.maxBps) / BPS;
        uint256 bal = IERC20(token).balanceOf(to);
        if (bal > cap) revert MaxWalletExceeded(to, bal, cap);
    }

    function maxWallet(PoolId id) external view returns (uint256 cap, uint256 until) {
        Rule storage r = _rules[id];
        cap = (TOTAL_SUPPLY * r.cfg.maxBps) / BPS;
        uint256 opened = _openedAt(id);
        until = r.cfg.duration == 0 ? type(uint256).max : opened == 0 ? 0 : opened + r.cfg.duration;
    }
}
