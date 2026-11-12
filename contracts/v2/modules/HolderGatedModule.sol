// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {ReceiverRuleBase} from "./ReceiverRuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {BalanceRead} from "./lib/BalanceRead.sol";

/// @title HolderGatedModule
/// @notice Transfer rule: an account may only RECEIVE this token (a curve buy, a pool buy or a wallet-to-wallet
///         transfer) while it holds at least `minBalance` of `gateToken`, checked after the move. It runs from
///         launch (curve buys included) until `duration` seconds after the pool opens (0 = forever).
///   - The gate token must be an AvaxHook v2 token or a quote asset the live QuoteRegistry allows (e.g. HOOK,
///     USDC), checked at launch, so the creator can't use a token whose `balanceOf` it controls.
///   - Selling and sending are never limited: moves TO the PoolManager or the launchpad are exempt.
///   - Every token outflow of the PoolManager is a buy and checked (this pool, hookless or other pools of the
///     token, output taken before or after the swap), except this pool's LP withdrawals and fee collection,
///     covered by a per-transaction allowance (see ReceiverRuleBase). Token claims from the hook and
///     withdrawals from other pools must go to a qualifying address.
///   - Exempt receivers: the PoolManager, the launchpad, the hook, 0x…dEaD, this module, other modules of the
///     same pool and the creator.
///   - The gate token's `balanceOf` is read with a 50k gas budget; a failing read counts as 0 (refused).
///   - Contracts that hold tokens mid-route (some aggregators) are receivers too: they must hold the gate
///     token, so most aggregator buys fail while the gate runs; the AvaxHook router and the curve pay the
///     buyer directly.
///   - Bypass: the gate is a balance check at receive time, nothing more: borrowing the gate token for the
///     moment of the buy works, and liquidity added in one transaction and removed in a later one pays out
///     to anyone (see ReceiverRuleBase).
///   - Claims bypass guard (2026-11-12): While the gate applies (`duration` after the pool opens, or forever), pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract HolderGatedModule is ReceiverRuleBase {
    struct Config {
        address gateToken; // ERC-20 the receiver must hold
        uint256 minBalance; // in the gate token's own units, > 0
        uint32 duration; // seconds after the pool opens, 0 = forever (max 365 days)
    }

    struct Rule {
        Config cfg;
        address creator;
        bool registered;
    }

    uint32 public constant MAX_DURATION = 365 days;
    uint256 internal constant READ_GAS = 50_000;

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    error GateNotHeld(address receiver, uint256 gateBalance, uint256 minBalance);
    error BadGateToken();

    constructor(address _hook) ReceiverRuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY;
    }

    /// @dev Claims bypass guard: while the gate applies, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy && _active(ctx.poolId, _rules[ctx.poolId])) RouterOnlyGuard.check(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_RECEIVER_LIST;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.gateToken == address(0) || c.minBalance == 0 || c.duration > MAX_DURATION) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        if (c.gateToken == token || c.gateToken.code.length == 0) revert BadGateToken();
        _checkForeignToken(c.gateToken, token);
        (bool ok,) = BalanceRead.balanceOf(c.gateToken, address(this), READ_GAS);
        if (!ok) revert BadGateToken();
        r.cfg = c;
        r.creator = creator;
        r.registered = true;
        poolOf[token] = id;
        _registerPool(id, token, quote);
    }

    function onTransfer(PoolId id, address, address, address from, address to, uint256 amount) external override onlyHook {
        Rule storage r = _rules[id];
        if (to == r.creator || _plumbing(to) || !_active(id, r)) return;
        uint256 bal = _gateBalance(r.cfg.gateToken, to);
        if (bal < r.cfg.minBalance && !_excused(id, from, to, amount)) revert GateNotHeld(to, bal, r.cfg.minBalance);
    }

    // ---------------------------------------------------------------- views

    /// @return gateToken  the token receivers must hold
    /// @return minBalance how much of it (gate token units)
    /// @return until      when the gate lifts (type(uint256).max = never; 0 = pool not open yet, lasts until
    ///                    `duration` after it opens)
    function gate(address token) external view returns (address gateToken, uint256 minBalance, uint256 until) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        uint256 opened = _openedAt(id);
        until = r.cfg.duration == 0 ? type(uint256).max : opened == 0 ? 0 : opened + r.cfg.duration;
        return (r.cfg.gateToken, r.cfg.minBalance, until);
    }

    /// @notice Whether `wallet` may receive `token` right now.
    function canReceive(address token, address wallet) external view returns (bool) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        if (!r.registered || wallet == r.creator || _plumbing(wallet) || _isPoolModule(id, wallet) || !_active(id, r)) return true;
        return _gateBalance(r.cfg.gateToken, wallet) >= r.cfg.minBalance;
    }

    // ---------------------------------------------------------------- internals

    function _active(PoolId id, Rule storage r) internal view returns (bool) {
        if (r.cfg.duration == 0) return true;
        uint256 opened = _openedAt(id);
        return opened == 0 || block.timestamp < opened + r.cfg.duration;
    }

    function _gateBalance(address gateToken, address who) internal view returns (uint256) {
        return BalanceRead.balanceOr0(gateToken, who, READ_GAS);
    }
}
