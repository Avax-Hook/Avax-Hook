// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title P2pOnlyModule
/// @notice A peer-to-peer period right after graduation: for `window` seconds after the pool opens (1 hour ..
///         7 days) every pool swap is refused, buys AND sells, through the router, aggregators or straight into
///         the PoolManager. Tokens can only change hands wallet to wallet (OTC between curve buyers). When the
///         window ends the pool trades normally, forever.
///   - The bonding curve is untouched (v2 tokens can't move wallet to wallet on the curve anyway).
///   - Refusing sells is the point, so the module declares BLOCKS_SELLS; the window is capped at 7 days so
///     holders are never stuck for longer.
///   - Liquidity adds/removals are not touched. Over-the-counter trades are trust-based: the module moves
///     no value, so a P2P deal (tokens for AVAX) needs an escrow contract or trust between the parties.
contract P2pOnlyModule is HookModuleBase {
    struct Config {
        uint32 window; // seconds after the pool opens with no pool swaps: 1 hour .. 7 days
    }

    struct Rule {
        uint32 window;
        bool registered;
    }

    uint32 public constant MIN_WINDOW = 1 hours;
    uint32 public constant MAX_WINDOW = 7 days;

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    /// @param opensAt when pool trading starts
    error PeerToPeerOnly(uint256 opensAt);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_VENUE;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.window < MIN_WINDOW || c.window > MAX_WINDOW) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        (r.window, r.registered) = (abi.decode(config, (Config)).window, true);
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.phase == ModuleCaps.PHASE_POOL) {
            uint256 opensAt = _openedAt(ctx.poolId) + _rules[ctx.poolId].window;
            if (block.timestamp < opensAt) revert PeerToPeerOnly(opensAt);
        }
        return (0, new Credit[](0));
    }

    // ---------------------------------------------------------------- views

    /// @return opensAt when pool swaps start (0 = still on the curve: the window starts when the pool opens)
    /// @return p2p     whether the peer-to-peer period is running now
    function status(address token) external view returns (uint256 opensAt, bool p2p) {
        PoolId id = poolOf[token];
        uint256 opened = _openedAt(id);
        if (opened == 0) return (0, false);
        opensAt = opened + _rules[id].window;
        p2p = block.timestamp < opensAt;
    }
}
