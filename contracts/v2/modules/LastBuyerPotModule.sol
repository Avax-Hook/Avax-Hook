// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";
import {ISnipeTaxSink} from "./AntiSnipeModule.sol";

/// @title LastBuyerPotModule
/// @notice v1 "Last-buyer pot": `potBps` of every pool buy's quote input fills a pot (plus the snipe tax when
///         the pool has no Nth-buy pot). Every qualifying buy restarts the clock and takes the lead. Once
///         `timerSeconds` pass without a qualifying buy the leader takes the whole pot: at the next qualifying
///         buy (which then starts a new round) or through the permissionless `settle`.
///   Qualifying (HK-3): a router buy (trusted buyer identity) of at least `minBuy` quote units; the core makes
///   every buy fill completely. A pot nobody leads (filled only by snipe tax or non-router buys) goes to the
///   creator after `TIMER_ORPHAN_SECONDS` (30 days) without a qualifying buy, so it can't sit stuck (I-1).
///   Both phases: bonding-curve buys (the launchpad names the buyer) fill the pot and lead like pool buys.
contract LastBuyerPotModule is LedgerModuleBase, ISnipeTaxSink {
    struct Config {
        uint16 potBps; // 1 .. 1,000 (10%)
        uint32 timerSeconds; // 60 .. 7 days
        uint96 minBuy; // quote units, > 0
    }

    /// @dev Flat and packed: a guarded first buy must fit the hook's 200k module gas.
    struct Pot {
        uint16 potBps;
        uint32 timerSeconds;
        uint96 minBuy;
        uint64 lastBuyAt; // last qualifying buy (launch time until the first one)
        address quote;
        uint96 totalPaid;
        address creator;
        address leader;
        uint128 pot; // this pool's share of the module's claim
        uint120 unverified; // credits announced to the hook, not yet checked against its books
        bool live; // set at registration so the pot's slot is never fresh inside a gas-capped callback
    }

    uint16 public constant MAX_POT_BPS = 1_000;
    uint32 public constant MIN_TIMER = 60;
    uint32 public constant MAX_TIMER = 7 days;
    /// @notice A pot without a leader goes to the creator after this long with no qualifying buy.
    uint32 public constant TIMER_ORPHAN_SECONDS = 30 days;

    mapping(PoolId => Pot) internal _pots;

    event NewLeader(PoolId indexed id, address indexed leader, uint256 endsAt);
    event TimerPotWon(PoolId indexed id, address indexed winner, uint256 amount);

    error NotPoolModule();

    constructor(address _hook) LedgerModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure virtual override {
        Config memory c = abi.decode(config, (Config));
        if (c.potBps == 0 || c.potBps > MAX_POT_BPS || c.minBuy == 0) revert BadConfig();
        if (c.timerSeconds < MIN_TIMER || c.timerSeconds > MAX_TIMER) revert BadConfig();
    }

    function onRegister(PoolId id, address, address quote, address creator, bytes calldata config) external override onlyHook {
        Pot storage p = _pots[id];
        if (p.creator != address(0)) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (p.potBps, p.timerSeconds, p.minBuy) = (c.potBps, c.timerSeconds, c.minBuy);
        p.quote = quote;
        p.live = true;
        _seed(quote);
        p.creator = creator;
        p.lastBuyAt = uint64(block.timestamp); // starts the orphaned-pot clock
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory credits) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        uint256 fresh = _reconcile();
        Pot storage p = _pots[ctx.poolId];
        uint256 share = (ctx.amountIn * p.potBps) / BPS;
        address winner;

        if (ctx.trader != address(0) && ctx.amountIn >= p.minBuy) {
            // A finished round is paid first, this buy's share included (as in v1), then this buyer leads.
            winner = _winner(p);
            if (winner != address(0)) {
                // Snipe tax announced earlier in this same callback isn't booked yet: it stays in the pot.
                uint256 held = p.pot - fresh;
                p.leader = address(0);
                if (held + share > 0) {
                    p.pot = uint128(fresh);
                    p.totalPaid += uint96(held + share);
                    if (held > 0) _payClaim(p.quote, winner, held);
                    emit TimerPotWon(ctx.poolId, winner, held + share);
                }
            }
            p.leader = ctx.trader;
            p.lastBuyAt = uint64(block.timestamp);
            emit NewLeader(ctx.poolId, ctx.trader, block.timestamp + p.timerSeconds);
        }
        if (share == 0) return (0, new Credit[](0));
        if (winner != address(0)) return (0, _one(winner, share));
        p.pot += uint128(share);
        p.unverified += uint120(share);
        _expect(ctx.poolId, p.quote, share);
        return (0, _one(address(this), share));
    }

    /// @notice Pays out a round whose quiet time has passed (or an orphaned pot to the creator). Anyone.
    function settle(PoolId id) external {
        _reconcile();
        Pot storage p = _pots[id];
        address winner = _winner(p);
        if (winner == address(0)) return;
        p.leader = address(0);
        uint256 held = p.pot;
        if (held == 0) return;
        p.pot = 0;
        p.totalPaid += uint96(held);
        _payClaim(p.quote, winner, held);
        emit TimerPotWon(id, winner, held);
    }

    // ---------------------------------------------------------------- snipe tax sink

    function snipeTaxSinkPriority() external pure returns (uint8) {
        return 2; // v1: only when the pool has no Nth-buy pot
    }

    /// @notice Called by another module of pool `id` (AntiSnipeModule) during a swap callback in which it
    ///         credits `amount` to this module. Checked against the real balance on the next reconcile.
    function addSnipeTax(PoolId id, uint256 amount) external {
        Pot storage p = _pots[id];
        if (p.creator == address(0) || !_isPoolModule(id, msg.sender)) revert NotPoolModule();
        _reconcile();
        p.pot += uint128(amount);
        p.unverified += uint120(amount);
        _expect(id, p.quote, amount);
    }

    // ---------------------------------------------------------------- views

    function potOf(PoolId id) external view returns (Pot memory) {
        return _pots[id];
    }

    /// @notice When the current round ends (0 = no leader; an orphaned pot is due at lastBuyAt + 30 days).
    function endsAt(PoolId id) external view returns (uint256) {
        Pot storage p = _pots[id];
        return p.leader == address(0) ? 0 : uint256(p.lastBuyAt) + p.timerSeconds;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Who a finished round pays now: the leader after the quiet time, the creator for an orphaned pot.
    function _winner(Pot storage p) internal view virtual returns (address) {
        address leader = p.leader;
        if (leader == address(0)) {
            return block.timestamp >= uint256(p.lastBuyAt) + TIMER_ORPHAN_SECONDS ? p.creator : address(0);
        }
        return block.timestamp >= uint256(p.lastBuyAt) + p.timerSeconds ? leader : address(0);
    }

    function _takeShare(PoolId id) internal override returns (address, uint256 amount) {
        Pot storage p = _pots[id];
        amount = p.pot;
        p.pot = 0;
        return (p.quote, amount);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Pot storage p = _pots[id];
        return (p.quote, p.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Pot storage p = _pots[id];
        p.pot = shortfall > p.pot ? 0 : p.pot - uint128(shortfall);
        p.unverified = 0;
    }
}
