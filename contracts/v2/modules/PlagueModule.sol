// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {ReceiverRuleBase} from "./ReceiverRuleBase.sol";
import {BalanceRead} from "./lib/BalanceRead.sol";

/// @title PlagueModule
/// @notice Once the pool opens, an uninfected wallet can only get this token from an infected one. Everyone who
///         bought on the bonding curve is infected (patient zeros, plus the creator). Receiving at least
///         `minInfect` tokens in one transfer from an infected account infects a wallet. Infected is forever.
///         The plague runs until `duration` seconds after the pool opens (0 = forever, at most 365 days
///         otherwise); afterwards anything goes.
///   While it runs, an uninfected receiver is refused unless the tokens come from:
///   - the launchpad (a curve buy; the receiver is infected),
///   - an infected sender (a transfer of at least `minInfect` infects the receiver if it is a wallet),
///   - the hook or a module of this pool (payouts), or
///   - the PoolManager within this transaction's LP-withdrawal allowance of this pool (see ReceiverRuleBase).
///   So pool buys of uninfected wallets are refused on this token's pool AND on any other pool or DEX pair of
///   the token (a hookless v4 pool, a contract pair, an aggregator handing tokens on), whenever the output is
///   taken. Uninfected CONTRACTS may receive from anyone but the PoolManager (aggregator pulls, liquidity
///   deposits), so uninfected holders can still sell through aggregators and DEX pairs; such a contract
///   can't hand the tokens on to an uninfected wallet.
///   - Only accounts without code (or with an EIP-7702 delegation) are infected by a transfer. That does NOT
///     stop public carriers: an infected wallet can infect a counterfactual address before a contract is
///     deployed there (CREATE2), or an infected wallet can delegate (EIP-7702) to code that buys for anyone.
///   - Selling and sending are never limited. LPs of this pool always get their liquidity and fees back. A
///     non-infected LP of a hookless pool of the token, or a non-infected claimant of token credits in the
///     hook, must withdraw / claim to an infected address.
///   - Bypasses: one infected wallet can infect any number of fresh wallets for `minInfect` each; carriers as
///     above; liquidity added in one transaction and removed in a later one pays out to anyone.
///   - Claims bypass guard (2026-11-12): While the plague is on (`duration` after the pool opens, or forever), pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract PlagueModule is ReceiverRuleBase {
    struct Config {
        uint128 minInfect; // tokens (18 decimals) one transfer must carry to infect: 1 .. 1% of supply
        uint32 duration; // seconds after the pool opens, 0 = forever (max 365 days)
    }

    struct Rule {
        uint128 minInfect;
        uint32 duration;
        address creator;
        address token;
        bool registered;
    }

    uint32 public constant MAX_DURATION = 365 days;
    uint256 public constant MAX_MIN_INFECT = TOTAL_SUPPLY / 100;

    mapping(PoolId => Rule) internal _rules;
    mapping(PoolId => mapping(address => bool)) internal _infected;
    mapping(address => PoolId) public poolOf;

    event Infected(address indexed token, address indexed from, address indexed to);

    error NotInfected(address buyer);

    constructor(address _hook) ReceiverRuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY;
    }

    /// @dev Claims bypass guard: while the plague is on, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy && _plagueOn(ctx.poolId, _rules[ctx.poolId])) RouterOnlyGuard.check(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_RECEIVER_LIST;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.minInfect == 0 || c.minInfect > MAX_MIN_INFECT || c.duration > MAX_DURATION) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (r.minInfect, r.duration, r.creator, r.token, r.registered) = (c.minInfect, c.duration, creator, token, true);
        _infected[id][creator] = true;
        poolOf[token] = id;
        _registerPool(id, token, quote);
        emit Infected(token, address(0), creator);
    }

    function onTransfer(PoolId id, address token, address, address from, address to, uint256 amount) external override onlyHook {
        Rule storage r = _rules[id];
        if (from == IAvaxHookV2View(hook).launchpad()) {
            // a curve buy: never refused, the receiver is infected
            if (!_plumbing(to) && !_isInfected(id, r, to)) {
                _infected[id][to] = true;
                emit Infected(token, from, to);
            }
            return;
        }
        if (_plumbing(to) || _isInfected(id, r, to)) return;
        bool fromPm = from == address(poolManager);
        if (!fromPm && _isInfected(id, r, from)) {
            // an infected sender: always fine; a big enough transfer infects a wallet
            if (amount >= r.minInfect && BalanceRead.isEoa(to)) {
                _infected[id][to] = true;
                emit Infected(token, from, to);
            }
            return;
        }
        if (!_plagueOn(id, r)) return;
        // uninfected contracts are conduits for anything but PoolManager outflows (sells through aggregators,
        // adding liquidity, deposits); they can't pass the tokens on to an uninfected wallet
        if (!fromPm && !BalanceRead.isEoa(to)) return;
        if (_excused(id, from, to, amount)) return;
        revert NotInfected(to);
    }

    // ---------------------------------------------------------------- views

    function infected(address token, address wallet) external view returns (bool) {
        PoolId id = poolOf[token];
        return _isInfected(id, _rules[id], wallet);
    }

    /// @notice Whether `wallet` can buy `token` right now (curve buys always can).
    function canBuy(address token, address wallet) external view returns (bool) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        return !r.registered || _openedAt(id) == 0 || !_plagueOn(id, r) || _isInfected(id, r, wallet);
    }

    /// @return minInfect smallest infecting transfer
    /// @return until     when buys open to everyone (type(uint256).max = never; 0 = pool not open yet)
    function plague(address token) external view returns (uint256 minInfect, uint256 until) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        uint256 opened = _openedAt(id);
        until = r.duration == 0 ? type(uint256).max : opened == 0 ? 0 : opened + r.duration;
        return (r.minInfect, until);
    }

    // ---------------------------------------------------------------- internals

    function _isInfected(PoolId id, Rule storage r, address a) internal view returns (bool) {
        return a == r.creator || _infected[id][a];
    }

    function _plagueOn(PoolId id, Rule storage r) internal view returns (bool) {
        if (r.duration == 0) return true;
        uint256 opened = _openedAt(id);
        return opened == 0 || block.timestamp < opened + r.duration;
    }
}
