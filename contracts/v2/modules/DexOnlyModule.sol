// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {BalanceRead} from "./lib/BalanceRead.sol";

/// @title DexOnlyModule
/// @notice Transfer rule: wallet-to-wallet sends are refused, swaps work. A move is refused when neither side
///         is plumbing (the PoolManager, the launchpad, the hook, 0x…dEaD, this module) AND both sides are
///         externally owned accounts (no code, or only an EIP-7702 delegation designator). Runs until
///         `duration` seconds after the pool opens (0 = forever, at most 365 days otherwise).
///   - Buys (from the PoolManager / launchpad) and sells (to them) always pass, so no BLOCKS_SELLS.
///   - Contract-to-wallet (aggregator sweeps, claims, vesting contracts) and wallet-to-contract (deposits into
///     routers, LP managers, a Safe) pass.
///   - On the bonding curve wallet sends are impossible anyway (tokens are locked until graduation).
///   - A 7702-delegated wallet sending directly is still `from` = that wallet (an EOA), so it is refused.
///   - Bypass, by design of EOA detection on the EVM: passing the tokens through any contract with code (a Safe
///     or smart-contract wallet that holds them, a forwarding contract), or to/from a contract under
///     construction, gets around it. It stops casual peer-to-peer sends and OTC hand-offs between plain
///     wallets, not determined users.
contract DexOnlyModule is HookModuleBase {
    struct Config {
        uint32 duration; // seconds after the pool opens, 0 = forever (max 365 days)
    }

    struct Rule {
        uint32 duration;
        bool registered;
    }

    uint32 public constant MAX_DURATION = 365 days;

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    error WalletToWallet(address from, address to);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.ON_TRANSFER;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_VENUE;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.duration > MAX_DURATION) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.duration = abi.decode(config, (Config)).duration;
        r.registered = true;
        poolOf[token] = id;
    }

    function onTransfer(PoolId id, address, address, address from, address to, uint256) external view override onlyHook {
        if (!_active(id, _rules[id])) return;
        if (_refused(from, to)) revert WalletToWallet(from, to);
    }

    // ---------------------------------------------------------------- views

    /// @notice Whether a `from` -> `to` move of `token` would be refused right now.
    function wouldRefuse(address token, address from, address to) external view returns (bool) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        return r.registered && _active(id, r) && _refused(from, to);
    }

    /// @return until when wallet sends open (type(uint256).max = never; 0 = pool not open yet)
    function activeUntil(address token) external view returns (uint256 until) {
        PoolId id = poolOf[token];
        uint32 d = _rules[id].duration;
        uint256 opened = _openedAt(id);
        until = d == 0 ? type(uint256).max : opened == 0 ? 0 : opened + d;
    }

    // ---------------------------------------------------------------- internals

    function _refused(address from, address to) internal view returns (bool) {
        if (_plumbing(from) || _plumbing(to)) return false;
        return BalanceRead.isEoa(from) && BalanceRead.isEoa(to);
    }

    function _plumbing(address a) internal view returns (bool) {
        return a == address(poolManager) || a == hook || a == ModuleCaps.BURN || a == address(this)
            || a == IAvaxHookV2View(hook).launchpad();
    }

    function _active(PoolId id, Rule storage r) internal view returns (bool) {
        if (r.duration == 0) return true;
        uint256 opened = _openedAt(id);
        return opened == 0 || block.timestamp < opened + r.duration;
    }
}
