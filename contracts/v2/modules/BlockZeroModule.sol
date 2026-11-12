// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";

/// @title BlockZeroModule
/// @notice The creator gets the first blocks to themselves: for the first `blocks` blocks after the launch only
///         the creator can buy on the bonding curve (`ctx.trader == creator`; the dev buy in the launch
///         transaction passes). Optionally the same for the first `poolBlocks` blocks after the pool opens: pool
///         buys are refused unless they come through the AvaxHook router with the creator as the trader
///         (aggregators and direct PoolManager swaps carry no trader, so they are refused in that window).
///   - Sells are never refused (no BLOCKS_SELLS) and the module never blocks transfers.
///   - Trusted callers that buy for someone (e.g. the Zap's buyWithQuoteFor) pass if the recipient is the creator.
///   - It keeps bots out of the first blocks; it does not stop the creator from buying big or handing tokens out.
contract BlockZeroModule is WindowedModuleBase {
    struct Config {
        uint8 blocks; // curve: 1 .. 20 blocks after the launch, creator only
        uint8 poolBlocks; // pool: 0 (off) .. 20 blocks after the pool opens, creator only
    }

    struct Rule {
        Config cfg;
        address creator;
        bool registered;
    }

    uint8 public constant MAX_BLOCKS = 20;

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    /// @param untilBlock first block anyone can buy
    error CreatorOnly(uint256 untilBlock);

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.blocks == 0 || c.blocks > MAX_BLOCKS || c.poolBlocks > MAX_BLOCKS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address creator, bytes calldata config)
        external
        override
        onlyHook
    {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        (r.cfg, r.creator, r.registered) = (abi.decode(config, (Config)), creator, true);
        poolOf[token] = id;
        _seedWindows(id);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy) {
            Rule memory r = _rules[ctx.poolId];
            bool curve = ctx.phase == ModuleCaps.PHASE_CURVE;
            uint256 window = curve ? r.cfg.blocks : r.cfg.poolBlocks;
            if (ctx.trader != r.creator && _inWindow(ctx, window)) {
                uint256 from = curve ? _launchBlock[ctx.poolId] : _openBlock(ctx.poolId);
                revert CreatorOnly(from + window);
            }
        }
        return (0, new Credit[](0));
    }

    // ---------------------------------------------------------------- views

    /// @notice Whether only the creator can buy right now, and the first block anyone can.
    function creatorOnly(address token) external view returns (bool on, uint256 untilBlock) {
        PoolId id = poolOf[token];
        Rule memory r = _rules[id];
        if (!r.registered) return (false, 0);
        uint256 open = _openBlockView(id);
        uint256 window = open == 0 ? r.cfg.blocks : r.cfg.poolBlocks;
        uint256 start = open == 0 ? _launchBlock[id] : open;
        untilBlock = start + window;
        on = window != 0 && block.number < untilBlock;
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    function creatorOf(address token) external view returns (address) {
        return _rules[poolOf[token]].creator;
    }
}
