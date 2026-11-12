// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title KingOfTheHillModule
/// @notice The largest qualifying single buy holds the crown, and the King earns a share of every trade.
///   - Crowning: a buy through the trusted router (buyer identity) of at least `minCrownBuy` quote units
///     takes the crown if there is no King, or if it is at least `beatBps` above the current bar.
///   - The bar is the King's winning buy, halving every `decayPeriod` seconds (smoothly in between;
///     0 = never decays). Re-buying above your own bar refreshes it.
///   - While crowned, the King earns `kingFeeBps` of every trade's quote amount (buys: from the input;
///     sells: from the output), credited as a claimable balance in AvaxHookV2.
///   - The King loses the crown on any sell or any outgoing token transfer (aggregator sells move tokens
///     out of the King's wallet too, so they are caught by the transfer callback).
///   - Buys not through the trusted router can't win the crown (their buyer can't be identified), but
///     still pay the King. The creator can't be King unless `creatorCanBeKing`.
///   Events give the UI a Hall of Kings and reign times: Crowned / Dethroned / KingPaid.
contract KingOfTheHillModule is HookModuleBase {
    struct Config {
        uint128 minCrownBuy; // quote units
        uint16 beatBps; // a challenger must beat the bar by this much
        uint16 kingFeeBps; // King's share of every trade's quote amount
        uint32 decayPeriod; // seconds for the bar to halve, 0 = never
        bool creatorCanBeKing;
    }

    struct Hill {
        Config cfg;
        address token;
        address king;
        uint128 winningBuy;
        uint64 since;
        uint128 totalPaid;
    }

    enum Reason {
        None,
        Beaten,
        Sold,
        Transferred
    }

    uint16 public constant MAX_KING_FEE_BPS = 200;
    uint32 public constant MIN_DECAY = 60;
    uint32 public constant MAX_DECAY = 365 days;

    mapping(PoolId => Hill) internal _hills;
    mapping(address => PoolId) public poolOf;

    event Crowned(address indexed token, address indexed king, uint256 amount, uint256 timestamp);
    event Dethroned(address indexed token, address indexed king, Reason reason);
    event KingPaid(address indexed token, address indexed king, uint256 amount);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_CROWN;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.minCrownBuy == 0 || c.beatBps == 0 || c.beatBps > BPS) revert BadConfig();
        if (c.kingFeeBps == 0 || c.kingFeeBps > MAX_KING_FEE_BPS) revert BadConfig();
        if (c.decayPeriod != 0 && (c.decayPeriod < MIN_DECAY || c.decayPeriod > MAX_DECAY)) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Hill storage h = _hills[id];
        if (h.token != address(0)) revert AlreadyRegistered();
        h.cfg = abi.decode(config, (Config));
        h.token = token;
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory credits) {
        Hill storage h = _hills[ctx.poolId];
        address king = h.king;
        if (!ctx.isBuy) {
            // A sell through the router names the seller: the King is out before this trade pays anyone.
            if (king != address(0) && ctx.trader == king) _dethrone(h, king, Reason.Sold);
            return (0, new Credit[](0));
        }
        // The current King earns from this buy, even one that dethrones them.
        if (king != address(0)) credits = _pay(h, king, ctx.amountIn);
        else credits = new Credit[](0);

        address trader = ctx.trader;
        Config memory c = h.cfg;
        if (trader == address(0) || ctx.amountIn < c.minCrownBuy) return (0, credits);
        if (trader == ctx.creator && !c.creatorCanBeKing) return (0, credits);
        if (king != address(0) && ctx.amountIn < _required(h)) return (0, credits);
        if (king != address(0) && king != trader) emit Dethroned(h.token, king, Reason.Beaten);
        h.king = trader;
        h.winningBuy = uint128(ctx.amountIn);
        h.since = uint64(block.timestamp);
        emit Crowned(h.token, trader, ctx.amountIn, block.timestamp);
        return (0, credits);
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        Hill storage h = _hills[ctx.poolId];
        address king = h.king;
        if (king == address(0)) return new Credit[](0);
        return _pay(h, king, ctx.amountOut);
    }

    function onTransfer(PoolId id, address, address, address from, address to, uint256 amount) external override onlyHook {
        if (amount == 0) return; // zero-value transferFrom needs no allowance: it must not dethrone anyone
        Hill storage h = _hills[id];
        address king = h.king;
        if (king == address(0) || from != king) return;
        _dethrone(h, king, to == address(poolManager) ? Reason.Sold : Reason.Transferred);
    }

    // ---------------------------------------------------------------- views

    /// @return king       current King (address(0) if none)
    /// @return winningBuy the King's crowning buy, quote units
    /// @return bar        the decayed bar now (a challenger needs bar * (1 + beatBps))
    /// @return since      when the King was crowned
    function currentKing(address token) external view returns (address king, uint256 winningBuy, uint256 bar, uint256 since) {
        Hill storage h = _hills[poolOf[token]];
        return (h.king, h.winningBuy, _bar(h), h.since);
    }

    /// @notice Smallest router buy that takes the crown now (quote units).
    function requiredToCrown(address token) external view returns (uint256) {
        Hill storage h = _hills[poolOf[token]];
        if (h.king == address(0)) return h.cfg.minCrownBuy;
        uint256 r = _required(h);
        return r > h.cfg.minCrownBuy ? r : h.cfg.minCrownBuy;
    }

    function hill(address token) external view returns (Hill memory) {
        return _hills[poolOf[token]];
    }

    // ---------------------------------------------------------------- internals

    function _pay(Hill storage h, address king, uint256 amount) internal returns (Credit[] memory) {
        uint256 fee = (amount * h.cfg.kingFeeBps) / BPS;
        if (fee == 0) return new Credit[](0);
        h.totalPaid += uint128(fee);
        emit KingPaid(h.token, king, fee);
        return _one(king, fee);
    }

    function _dethrone(Hill storage h, address king, Reason reason) internal {
        h.king = address(0);
        h.winningBuy = 0;
        h.since = 0;
        emit Dethroned(h.token, king, reason);
    }

    function _required(Hill storage h) internal view returns (uint256) {
        uint256 bar = _bar(h);
        return (bar * (BPS + h.cfg.beatBps) + BPS - 1) / BPS;
    }

    /// @dev The winning buy halved once per elapsed period, linear between halvings.
    function _bar(Hill storage h) internal view returns (uint256) {
        uint256 w = h.winningBuy;
        uint256 period = h.cfg.decayPeriod;
        if (w == 0 || period == 0) return w;
        uint256 elapsed = block.timestamp - h.since;
        uint256 k = elapsed / period;
        if (k >= 128) return 0;
        uint256 hi = w >> k;
        uint256 lo = hi >> 1;
        return hi - ((hi - lo) * (elapsed % period)) / period;
    }
}
