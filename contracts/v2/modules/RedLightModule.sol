// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title RedLightModule
/// @notice Red light, green light: trading switches on and off in pseudo-random intervals.
///   Time from the launch is cut into slots of `slotSeconds`. Slot k is green with probability `greenBps`,
///   decided by keccak256(seed, k), where `seed` = keccak256(blockhash(launch block − 1), poolId) is fixed at
///   launch. The whole schedule is therefore public and predictable from the launch on (isGreen / nextChange /
///   slotGreen show it): it is a game, not a security feature. A creator can also pick the launch block, and so
///   the seed, by retrying.
///   - Red: buys are refused; sells are refused too unless `sellsOpen`. Green: everything trades.
///   - Safety valve: after `maxRedSlots` red slots in a row the next slot is always green, and
///     maxRedSlots · slotSeconds <= 1 hour, so trading is never closed for more than an hour in a row.
///     Slot 0 (the launch slot) is always green, so the dev buy in the launch transaction goes through.
///   - Slots follow block.timestamp, which validators can shift by a few seconds, so trades right at a slot
///     boundary may land on either side of it.
///   - Applies on the bonding curve and in the pool, to every route (router, aggregators, direct PoolManager).
///     Wallet-to-wallet transfers are never restricted. Declares BLOCKS_SELLS (red slots may close sells).
///   Gas: at most 1 + maxRedSlots keccak hashes per trade (<= 61, ~5k gas).
contract RedLightModule is HookModuleBase {
    struct Config {
        uint32 slotSeconds; // 10 s .. 1 hour per slot
        uint16 greenBps; // chance a slot is green: 10% .. 95%
        uint16 maxRedSlots; // red slots in a row before a forced green: 1 .. 60, and maxRedSlots · slotSeconds <= 1 h
        bool sellsOpen; // true: red slots close buys only
    }

    struct Light {
        Config cfg;
        uint40 start; // launch timestamp, start of slot 0
        bool registered;
        bytes32 seed;
    }

    uint32 public constant MIN_SLOT_SECONDS = 10;
    uint32 public constant MAX_SLOT_SECONDS = 1 hours;
    uint16 public constant MIN_GREEN_BPS = 1_000;
    uint16 public constant MAX_GREEN_BPS = 9_500;
    uint16 public constant MAX_RED_SLOTS = 60;
    uint256 public constant MAX_CLOSED = 1 hours;
    /// @dev nextChange looks this many slots ahead at most.
    uint256 public constant LOOKAHEAD = 512;

    mapping(PoolId => Light) internal _lights;
    mapping(address => PoolId) public poolOf;

    /// @param greenAt start of the next green slot
    error RedLight(uint256 greenAt);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SCHEDULE;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.slotSeconds < MIN_SLOT_SECONDS || c.slotSeconds > MAX_SLOT_SECONDS) revert BadConfig();
        if (c.greenBps < MIN_GREEN_BPS || c.greenBps > MAX_GREEN_BPS) revert BadConfig();
        if (c.maxRedSlots == 0 || c.maxRedSlots > MAX_RED_SLOTS) revert BadConfig();
        if (uint256(c.maxRedSlots) * c.slotSeconds > MAX_CLOSED) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Light storage l = _lights[id];
        if (l.registered) revert AlreadyRegistered();
        l.cfg = abi.decode(config, (Config));
        l.start = uint40(block.timestamp);
        l.registered = true;
        l.seed = keccak256(abi.encode(blockhash(block.number - 1), id));
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        Light memory l = _lights[ctx.poolId];
        if (ctx.isBuy || !l.cfg.sellsOpen) {
            uint256 k = _slotAt(l, block.timestamp);
            if (!_green(l, k)) revert RedLight(uint256(l.start) + _nextGreen(l, k) * l.cfg.slotSeconds);
        }
        return (0, new Credit[](0));
    }

    // ---------------------------------------------------------------- views

    /// @notice Whether trading is open now (sells may stay open in red slots when `sellsOpen`).
    function isGreen(address token) external view returns (bool) {
        Light memory l = _lights[poolOf[token]];
        if (!l.registered) return true;
        return _green(l, _slotAt(l, block.timestamp));
    }

    /// @notice Start of the next slot whose colour differs from now (0 if none within LOOKAHEAD slots).
    function nextChange(address token) external view returns (uint256) {
        Light memory l = _lights[poolOf[token]];
        if (!l.registered) return 0;
        return _nextChangeFrom(l, _slotAt(l, block.timestamp));
    }

    /// @notice The colour of slot `k` (k = 0 is the launch slot) and its start time, for a UI timeline.
    function slotGreen(address token, uint256 k) external view returns (bool green, uint256 startsAt) {
        Light memory l = _lights[poolOf[token]];
        return (_green(l, k), uint256(l.start) + k * l.cfg.slotSeconds);
    }

    function currentSlot(address token) external view returns (uint256) {
        Light memory l = _lights[poolOf[token]];
        if (!l.registered) return 0;
        return _slotAt(l, block.timestamp);
    }

    function configOf(address token) external view returns (Config memory) {
        return _lights[poolOf[token]].cfg;
    }

    function seedOf(address token) external view returns (bytes32) {
        return _lights[poolOf[token]].seed;
    }

    // ---------------------------------------------------------------- internals

    function _slotAt(Light memory l, uint256 t) internal pure returns (uint256) {
        return t > l.start ? (t - l.start) / l.cfg.slotSeconds : 0;
    }

    function _raw(Light memory l, uint256 k) internal pure returns (bool) {
        return uint256(keccak256(abi.encode(l.seed, k))) % BPS < l.cfg.greenBps;
    }

    /// @dev Green if the draw says so, or if the `maxRedSlots` slots before it all drew red (forced green).
    ///      A run of maxRedSlots + 1 red slots would need slot k red after maxRedSlots red draws: impossible.
    function _green(Light memory l, uint256 k) internal pure returns (bool) {
        if (k == 0 || _raw(l, k)) return true;
        uint256 m = l.cfg.maxRedSlots;
        for (uint256 j = 1; j <= m; ++j) {
            if (j >= k || _raw(l, k - j)) return false; // slot 0 is green: no forced green before it
        }
        return true;
    }

    /// @dev First green slot after red slot `k`, in at most 2 · maxRedSlots hashes: counts the red draws in a row
    ///      ending at k, then walks forward until a green draw or the forced green.
    function _nextGreen(Light memory l, uint256 k) internal pure returns (uint256 s) {
        uint256 m = l.cfg.maxRedSlots;
        uint256 run = 1; // slot k drew red
        while (run < m && run < k && !_raw(l, k - run)) ++run;
        for (s = k + 1;; ++s) {
            if (run >= m || _raw(l, s)) return s;
            ++run;
        }
    }

    function _nextChangeFrom(Light memory l, uint256 k) internal pure returns (uint256) {
        bool now_ = _green(l, k);
        if (!now_) return uint256(l.start) + _nextGreen(l, k) * l.cfg.slotSeconds;
        for (uint256 i = 1; i <= LOOKAHEAD; ++i) {
            if (_green(l, k + i) != now_) return uint256(l.start) + (k + i) * l.cfg.slotSeconds;
        }
        return 0;
    }
}
