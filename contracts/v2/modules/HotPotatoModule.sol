// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title HotPotatoModule
/// @notice The last qualifying buyer holds the potato: they can't sell or send a single token until a
///         DIFFERENT wallet makes a qualifying buy after them, or the cool-off (1 hour .. 7 days) runs out.
///   - Qualifying buy: a curve buy, or a pool buy through the AvaxHook router (the buyer is known),
///     receiving at least `minBuyBps` of the supply. Buying again while holding it restarts your own clock.
///   - The holder's every outgoing transfer is refused (router sells, aggregator sells, wallet sends, adding
///     liquidity), so the module declares BLOCKS_SELLS and needs the transfer callback. Receiving is fine.
///   - Nobody is exempt, the creator included.
///   - Buys the hook can't attribute (aggregators/bots calling the PoolManager directly): with
///     `refuseUnknownBuyers` they are refused, so every buyer can be handed the potato; without it they are
///     ignored — they neither take the potato nor free its holder (the holder can't escape by buying through
///     an aggregator, but such buyers dodge the risk). tx.origin is never used: it would hand the potato to
///     relayers and bundlers instead of the buyer.
///   - Bonding curve too: there the buyer is always known, a holder can't sell back to the curve, and
///     the last qualifying curve buyer still holds the potato when the pool opens.
contract HotPotatoModule is HookModuleBase {
    struct Config {
        uint16 minBuyBps; // tokens received, of the 1B supply: 0.01% .. 10%
        uint32 coolOff; // seconds after the holder's buy when they are freed anyway: 1 hour .. 7 days
        bool refuseUnknownBuyers; // refuse pool buys that do not come through the router (curve buyers are always known)
    }

    struct Potato {
        Config cfg; // 7 bytes
        address holder; // 20 bytes (same slot)
        uint64 since;
        address token;
        bool registered;
    }

    uint16 public constant MAX_MIN_BUY_BPS = 1_000;
    uint32 public constant MIN_COOL_OFF = 1 hours;
    uint32 public constant MAX_COOL_OFF = 7 days;

    mapping(PoolId => Potato) internal _potatoes;
    mapping(address => PoolId) public poolOf;

    event PotatoPassed(address indexed token, address indexed from, address indexed to, uint256 amount);

    error PotatoHeld(address holder, uint256 freeAt);
    error RouterBuysOnly();

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SELL_LOCK;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.minBuyBps == 0 || c.minBuyBps > MAX_MIN_BUY_BPS) revert BadConfig();
        // H-2: always a cool-off, so the last holder can never be locked for good (e.g. once buying stops).
        if (c.coolOff < MIN_COOL_OFF || c.coolOff > MAX_COOL_OFF) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Potato storage p = _potatoes[id];
        if (p.registered) revert AlreadyRegistered();
        p.cfg = abi.decode(config, (Config));
        p.token = token;
        p.registered = true;
        poolOf[token] = id;
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return new Credit[](0); // a holder's sell is stopped at its token transfer
        Potato storage p = _potatoes[ctx.poolId];
        address buyer = ctx.trader;
        if (buyer == address(0)) {
            if (p.cfg.refuseUnknownBuyers) revert RouterBuysOnly();
            return new Credit[](0);
        }
        if (ctx.amountOut < (TOTAL_SUPPLY * p.cfg.minBuyBps) / BPS) return new Credit[](0);
        address prev = _activeHolder(p);
        p.holder = buyer;
        p.since = uint64(block.timestamp);
        emit PotatoPassed(p.token, prev, buyer, ctx.amountOut);
        return new Credit[](0);
    }

    function onTransfer(PoolId id, address, address, address from, address, uint256 amount) external view override onlyHook {
        if (amount == 0) return; // zero-value moves change nothing
        Potato storage p = _potatoes[id];
        if (from != p.holder || from == address(0)) return;
        uint256 freeAt = _freeAt(p);
        if (block.timestamp < freeAt) revert PotatoHeld(from, freeAt);
    }

    // ---------------------------------------------------------------- views

    /// @return holder who holds the potato now (address(0) if nobody or the cool-off ran out)
    /// @return since  their qualifying buy
    /// @return freeAt when they are freed without a new buyer (type(uint256).max = only by a new buyer)
    function potato(address token) external view returns (address holder, uint256 since, uint256 freeAt) {
        Potato storage p = _potatoes[poolOf[token]];
        holder = _activeHolder(p);
        if (holder == address(0)) return (address(0), 0, 0);
        return (holder, p.since, _freeAt(p));
    }

    /// @notice Smallest buy (tokens received) that passes the potato.
    function minBuy(address token) external view returns (uint256) {
        return (TOTAL_SUPPLY * _potatoes[poolOf[token]].cfg.minBuyBps) / BPS;
    }

    /// @notice Whether `wallet` may send/sell tokens now.
    function canSell(address token, address wallet) external view returns (bool) {
        Potato storage p = _potatoes[poolOf[token]];
        return wallet != p.holder || block.timestamp >= _freeAt(p);
    }

    // ---------------------------------------------------------------- internals

    function _freeAt(Potato storage p) internal view returns (uint256) {
        uint32 cool = p.cfg.coolOff;
        return cool == 0 ? type(uint256).max : uint256(p.since) + cool;
    }

    function _activeHolder(Potato storage p) internal view returns (address) {
        address h = p.holder;
        if (h == address(0) || block.timestamp >= _freeAt(p)) return address(0);
        return h;
    }
}
