// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title AntiBundleModule
/// @notice At most `maxBuysPerBlock` buying transactions per block for a token, so a launch can't be swept by a
///         bundle of many buys packed into the first blocks.
///   - Counts buying TRANSACTIONS, not volume: several buy swaps inside one transaction (split routes, multi-hop
///     batches) count once (a transient per-transaction flag), so a single user's split route isn't refused.
///   - Only buys of at least `minBuyBps` of supply (tokens received, the whole transaction together) take a place,
///     so dust buys can't fill a block and lock honest buyers out; smaller buys pass uncounted. A buyer willing
///     to make min-size buys can still take the places of a block (that is the rule working as a per-block limit).
///   - Window: the first `blocks` blocks after the launch on the bonding curve, and again the first `blocks`
///     blocks after the pool opens (like WhaleGuard), at most 43,200 blocks each. Never forever.
///   - Every route counts: curve buys, router buys, aggregator / direct PoolManager buys. The dev buy in the
///     launch transaction counts as the launch block's first buy.
///   - Counts NET buying per transaction: tokens sold in the same transaction are taken off its tokens bought.
///     A transaction that buys and then sells back below `minBuyBps` net gives its place back, so a buy+sell
///     round trip can't fill the block's places and lock honest buyers out for the price of the fees. (A
///     buy and a sell in separate transactions are not netted: there is no reliable buyer identity, so a
///     place taken by a buying transaction stays taken; holding the tokens in between is that griefer's
///     cost and risk.)
///   - Sells are never refused (no BLOCKS_SELLS). Wallet-to-wallet transfers are untouched.
///   - It limits how many buyers land per block, not who they are: a bundler can still spread its buys over
///     consecutive blocks, and one transaction may still buy as much as other rules allow.
///   Gas: one storage slot read and written per counted buy (~7k).
contract AntiBundleModule is WindowedModuleBase, TxTally {
    struct Config {
        uint16 maxBuysPerBlock; // 1 .. 100 buying transactions per block
        uint32 blocks; // 1 .. 43,200 blocks per window
        uint16 minBuyBps; // smallest counted buy, of the 1B supply (tokens received): 0.01% .. 1%
    }

    /// @dev One slot: config plus the running count of the last block that saw a buy.
    struct Guard {
        uint16 maxBuysPerBlock;
        uint32 blocks;
        uint64 lastBlock;
        uint16 count; // buying transactions in `lastBlock`
        bool registered;
        uint16 minBuyBps;
    }

    uint16 public constant MAX_BUYS_PER_BLOCK = 100;
    uint32 public constant MAX_WINDOW_BLOCKS = 43_200;
    uint16 public constant MAX_MIN_BUY_BPS = 100;
    bytes32 internal constant SEEN = keccak256("avaxhook.v2.antibundle.tx");
    bytes32 internal constant SUM = keccak256("avaxhook.v2.antibundle.sum");
    bytes32 internal constant SOLD = keccak256("avaxhook.v2.antibundle.sold");

    mapping(PoolId => Guard) internal _guards;
    mapping(address => PoolId) public poolOf;

    error TooManyBuysThisBlock(uint256 maxBuysPerBlock);

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.maxBuysPerBlock == 0 || c.maxBuysPerBlock > MAX_BUYS_PER_BLOCK) revert BadConfig();
        if (c.blocks == 0 || c.blocks > MAX_WINDOW_BLOCKS) revert BadConfig();
        if (c.minBuyBps == 0 || c.minBuyBps > MAX_MIN_BUY_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Guard storage g = _guards[id];
        if (g.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (g.maxBuysPerBlock, g.blocks, g.minBuyBps, g.registered) = (c.maxBuysPerBlock, c.blocks, c.minBuyBps, true);
        poolOf[token] = id;
        _seedWindows(id);
    }

    /// @dev After the swap, where the tokens received are known (a revert here still refuses the buy).
    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        Guard memory g = _guards[ctx.poolId];
        if (!_inWindow(ctx, g.blocks)) return new Credit[](0);
        bytes32 k = keccak256(abi.encode(SEEN, ctx.poolId));
        uint256 min = (TOTAL_SUPPLY * g.minBuyBps) / BPS;
        if (!ctx.isBuy) {
            // tokens sold (exact input) come off this transaction's net buying
            uint256 sold = _tallyAdd(keccak256(abi.encode(SOLD, ctx.poolId)), ctx.amountIn);
            if (_tload(k) != 0 && _tload(keccak256(abi.encode(SUM, ctx.poolId))) < sold + min) {
                // net below a counted buy again: give the place back (this transaction took it, in this block)
                _tstore(k, 0);
                Guard storage gs = _guards[ctx.poolId];
                gs.count = g.count - 1;
            }
            return new Credit[](0);
        }
        uint256 sum = _tallyAdd(keccak256(abi.encode(SUM, ctx.poolId)), ctx.amountOut);
        if (_tload(k) != 0) return new Credit[](0); // this transaction already counted
        uint256 soldSoFar = _tload(keccak256(abi.encode(SOLD, ctx.poolId)));
        if (sum < soldSoFar + min) return new Credit[](0); // too small (net) to take a place (yet)
        _tstore(k, 1);
        uint16 n = g.lastBlock == block.number ? g.count : 0;
        if (n >= g.maxBuysPerBlock) revert TooManyBuysThisBlock(g.maxBuysPerBlock);
        Guard storage s = _guards[ctx.poolId];
        (s.lastBlock, s.count) = (uint64(block.number), n + 1);
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Whether the rule applies right now (the current phase's window, or always).
    function active(address token) public view returns (bool) {
        PoolId id = poolOf[token];
        Guard memory g = _guards[id];
        if (!g.registered) return false;
        return _activeView(id, g.blocks);
    }

    /// @notice Buying transactions still accepted in the current block (max when the rule is off).
    function buysLeftThisBlock(address token) external view returns (uint256) {
        Guard memory g = _guards[poolOf[token]];
        if (!active(token)) return g.maxBuysPerBlock;
        uint256 n = g.lastBlock == block.number ? g.count : 0;
        return n >= g.maxBuysPerBlock ? 0 : g.maxBuysPerBlock - n;
    }

    function configOf(address token) external view returns (Config memory c) {
        Guard memory g = _guards[poolOf[token]];
        (c.maxBuysPerBlock, c.blocks, c.minBuyBps) = (g.maxBuysPerBlock, g.blocks, g.minBuyBps);
    }
}
