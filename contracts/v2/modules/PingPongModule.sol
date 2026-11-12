// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title PingPongModule
/// @notice Buys and sells take turns, for everyone: after a buy only a sell can trade, after a sell only a buy.
///   - The first trade (on the curve) must be a buy.
///   - Only trades moving at least `minBps` of the supply (tokens received on a buy, tokens sold on a sell)
///     flip the turn. Smaller trades on the side whose turn it is go through without flipping it; trades
///     on the wrong side are refused whatever their size, so dust can't sneak a dump past the rule.
///   - If nobody takes the turn for `timeout` seconds after the last turn flip (or after the launch),
///     the turn is free: either side may trade, and the next counted trade sets the turn again.
///   - One trade per transaction: a second swap in the same transaction (either side) is refused, so a
///     single transaction can't play both sides.
///   Applies on the bonding curve and in the pool alike (one game: the turn carries over at graduation).
contract PingPongModule is HookModuleBase {
    struct Config {
        uint16 minBps; // trade size that flips the turn, of the 1B supply: 0.01% .. 5%
        uint32 timeout; // seconds until an untaken turn frees up: 1 min .. 7 days
    }

    enum Side {
        None, // nothing counted yet: buy's turn
        Buy, // last counted trade was a buy: sell's turn
        Sell // last counted trade was a sell: buy's turn
    }

    struct Table {
        Config cfg;
        Side last;
        uint64 at; // last turn flip (set to the launch time at registration)
        address token;
        bool registered;
    }

    uint16 public constant MAX_MIN_BPS = 500;
    uint32 public constant MIN_TIMEOUT = 60;
    uint32 public constant MAX_TIMEOUT = 7 days;

    mapping(PoolId => Table) internal _tables;
    mapping(address => PoolId) public poolOf;

    event Turn(address indexed token, bool buyWasCounted, uint256 amount, uint256 timestamp);

    /// @param buysTurn true when only buys may trade now
    /// @param freeAt   when the turn frees up for both sides
    error NotYourTurn(bool buysTurn, uint256 freeAt);
    error OneSwapPerTx();

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.AFTER_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_TURN;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.minBps == 0 || c.minBps > MAX_MIN_BPS) revert BadConfig();
        if (c.timeout < MIN_TIMEOUT || c.timeout > MAX_TIMEOUT) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Table storage t = _tables[id];
        if (t.registered) revert AlreadyRegistered();
        t.cfg = abi.decode(config, (Config));
        t.token = token;
        t.registered = true;
        t.at = uint64(block.timestamp); // the first turn (a buy) starts at launch
        poolOf[token] = id;
    }

    /// @dev After the swap so a buy's size (tokens out) is known; a revert here still undoes the trade.
    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.txSwaps > 1) revert OneSwapPerTx();
        Table storage t = _tables[ctx.poolId];
        Side side = ctx.isBuy ? Side.Buy : Side.Sell;
        (bool free, bool buysTurn, uint256 freeAt) = _turn(t);
        if (!free && ctx.isBuy != buysTurn) revert NotYourTurn(buysTurn, freeAt);
        uint256 size = ctx.isBuy ? ctx.amountOut : ctx.amountIn;
        if (size >= (TOTAL_SUPPLY * t.cfg.minBps) / BPS) {
            t.last = side;
            t.at = uint64(block.timestamp);
            emit Turn(t.token, ctx.isBuy, size, block.timestamp);
        }
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @return free     either side may trade now
    /// @return buysTurn if not free: true = only buys, false = only sells
    /// @return freeAt   when the current turn frees up
    function turn(address token) external view returns (bool free, bool buysTurn, uint256 freeAt) {
        return _turn(_tables[poolOf[token]]);
    }

    /// @notice Smallest trade (tokens) that flips the turn.
    function minTrade(address token) external view returns (uint256) {
        return (TOTAL_SUPPLY * _tables[poolOf[token]].cfg.minBps) / BPS;
    }

    function _turn(Table storage t) internal view returns (bool free, bool buysTurn, uint256 freeAt) {
        freeAt = uint256(t.at) + t.cfg.timeout;
        free = block.timestamp >= freeAt;
        buysTurn = t.last != Side.Buy;
    }
}
