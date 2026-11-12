// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";

/// @title BlocklistModule
/// @notice Transfer rule: up to 200 addresses named at launch can never receive this token, forever: no curve
///         buy, no pool buy, no token claim from the hook, no wallet-to-wallet transfer. The list is sealed in
///         onRegister and can't be changed by anyone.
///   - Selling and sending are never limited (a blocked address can't hold any tokens anyway).
///   - Plumbing can't be blocked: the PoolManager, the launchpad, the hook, 0x…dEaD, this module and the
///     pool's other modules are always exempt, even if listed.
///   - Bypass: a blocked person can simply use another wallet; this stops known addresses (a sniper bot, a
///     rival deployer, an exploiter's wallet), not people.
///   - Claims bypass guard (2026-11-12): The list is permanent, so always: pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract BlocklistModule is HookModuleBase {
    struct Config {
        address[] list; // 1 .. 200 addresses that can never receive
    }

    uint256 public constant MAX_ADDRESSES = 200;

    struct Rule {
        uint16 count;
        bool registered;
    }

    mapping(PoolId => Rule) internal _rules;
    mapping(PoolId => mapping(address => bool)) internal _blocked;
    mapping(address => PoolId) public poolOf;

    event Blocked(address indexed token, address indexed account);

    error ReceiverBlocked(address receiver);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER;
    }

    /// @dev Claims bypass guard: the list is permanent, so pool buys must always come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        RouterOnlyGuard.checkBuy(ctx);
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_RECEIVER_LIST;
    }

    /// @dev Config: `abi.encode(Config({list}))`, 1..200 entries, no zero address. Duplicates are harmless.
    function validateConfig(bytes calldata config) public pure override {
        address[] memory list = abi.decode(config, (Config)).list;
        uint256 n = list.length;
        if (n == 0 || n > MAX_ADDRESSES) revert BadConfig();
        for (uint256 i; i < n; ++i) {
            if (list[i] == address(0)) revert BadConfig();
        }
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        address[] memory list = abi.decode(config, (Config)).list;
        mapping(address => bool) storage b = _blocked[id];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (b[list[i]]) continue;
            b[list[i]] = true;
            emit Blocked(token, list[i]);
        }
        r.count = uint16(n);
        r.registered = true;
        poolOf[token] = id;
    }

    function onTransfer(PoolId id, address, address, address, address to, uint256) external view override onlyHook {
        if (!_blocked[id][to] || _plumbing(to) || _isPoolModule(id, to)) return;
        revert ReceiverBlocked(to);
    }

    // ---------------------------------------------------------------- views

    function isBlocked(address token, address account) external view returns (bool) {
        return _blocked[poolOf[token]][account] && !_plumbing(account);
    }

    /// @notice Length of the list given at launch (duplicates included); the addresses are in the Blocked events.
    function listSize(address token) external view returns (uint256) {
        return _rules[poolOf[token]].count;
    }

    /// @dev Modules of the same pool (Auto-LP vaults, pots) can't be blocked either.
    function _isPoolModule(PoolId id, address a) internal view returns (bool) {
        if (a.code.length == 0) return false;
        address[] memory mods = AvaxHookV2(payable(hook)).poolInfo(id).modules;
        for (uint256 i; i < mods.length; ++i) {
            if (mods[i] == a) return true;
        }
        return false;
    }

    function _plumbing(address a) internal view returns (bool) {
        return a == address(poolManager) || a == hook || a == ModuleCaps.BURN || a == address(this)
            || a == IAvaxHookV2View(hook).launchpad();
    }
}
