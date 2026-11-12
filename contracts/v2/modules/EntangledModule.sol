// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {IBeaconModule} from "./BeaconModule.sol";

/// @title EntangledModule
/// @notice The pool stays locked, no buys and no sells, until another token, its beacon, first reaches a
///         target USD market cap. From then on it trades freely, forever.
///   - The beacon is an AvaxHook v2 token launched with the Beacon module, which records its all-time-high
///     USD market cap (prices that stood into a later block, see BeaconModule). The beacon must be launched
///     before this token; it doesn't have to have graduated.
///   - Safety valve: `maxLock` seconds after launch, it unlocks anyway, so holders can never be
///     locked in for good (for example if the beacon is abandoned or its Beacon module is disabled).
///   - The bonding curve is locked too (so the token can't graduate before it unlocks; a launch with a dev
///     buy reverts while locked). Wallet-to-wallet transfers are never restricted.
///   Locking sells is the point of the rule, so the module declares BLOCKS_SELLS.
contract EntangledModule is HookModuleBase {
    struct Config {
        address beaconToken; // the token whose market cap unlocks this one
        uint64 targetUsd; // whole US dollars: $1k .. $1T
        uint32 maxLock; // seconds after launch when it unlocks regardless: 1 hour .. 365 days
    }

    struct Link {
        Config cfg;
        address beacon; // the beacon token's Beacon module
        address token;
        uint64 launchedAt;
        bool unlocked;
        bool registered;
    }

    uint64 public constant MIN_TARGET_USD = 1_000;
    uint64 public constant MAX_TARGET_USD = 1e12;
    uint32 public constant MIN_LOCK = 1 hours;
    uint32 public constant MAX_LOCK = 365 days;

    mapping(PoolId => Link) internal _links;
    mapping(address => PoolId) public poolOf;

    event Unlocked(address indexed token, address indexed beaconToken, uint256 beaconAthUsd, bool byTimeout);

    /// @param athUsd    the beacon's ATH market cap now (18 decimals)
    /// @param targetUsd the target (18 decimals)
    /// @param unlocksAt the safety-valve time
    error Locked(uint256 athUsd, uint256 targetUsd, uint256 unlocksAt);
    error NoBeacon();

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SELL_LOCK;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.beaconToken == address(0)) revert BadConfig();
        if (c.targetUsd < MIN_TARGET_USD || c.targetUsd > MAX_TARGET_USD) revert BadConfig();
        if (c.maxLock < MIN_LOCK || c.maxLock > MAX_LOCK) revert BadConfig();
    }

    /// @dev Finds the beacon token's Beacon module among its pool's modules (reverts if there is none).
    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Link storage k = _links[id];
        if (k.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        if (c.beaconToken == token) revert NoBeacon();
        k.cfg = c;
        k.beacon = findBeacon(c.beaconToken);
        if (k.beacon == address(0)) revert NoBeacon();
        k.token = token;
        k.launchedAt = uint64(block.timestamp);
        k.registered = true;
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        Link storage k = _links[ctx.poolId];
        if (k.unlocked) return (0, new Credit[](0));
        (bool open, uint256 ath, uint256 unlocksAt) = _check(k);
        if (!open) revert Locked(ath, uint256(k.cfg.targetUsd) * 1e18, unlocksAt);
        k.unlocked = true;
        emit Unlocked(k.token, k.cfg.beaconToken, ath, ath < uint256(k.cfg.targetUsd) * 1e18);
        return (0, new Credit[](0));
    }

    // ---------------------------------------------------------------- views

    /// @notice The Beacon module of `beaconToken`'s pool, or address(0).
    function findBeacon(address beaconToken) public view returns (address) {
        AvaxHookV2 h = AvaxHookV2(payable(hook));
        AvaxHookV2.PoolView memory v = h.poolInfo(h.poolOfToken(beaconToken));
        if (v.token != beaconToken) return address(0);
        for (uint256 i; i < v.modules.length; ++i) {
            try IBeaconModule(v.modules[i]).isBeacon() returns (bytes4 magic) {
                if (magic == IBeaconModule.isBeacon.selector) return v.modules[i];
            } catch {}
        }
        return address(0);
    }

    /// @return unlocked  whether the pool trades now
    /// @return athUsd    the beacon's ATH market cap (18 decimals)
    /// @return targetUsd the target (18 decimals)
    /// @return unlocksAt the safety-valve time
    function status(address token) external view returns (bool unlocked, uint256 athUsd, uint256 targetUsd, uint256 unlocksAt) {
        Link storage k = _links[poolOf[token]];
        (unlocked, athUsd, unlocksAt) = _check(k);
        unlocked = unlocked || k.unlocked;
        targetUsd = uint256(k.cfg.targetUsd) * 1e18;
    }

    function link(address token) external view returns (Config memory cfg, address beacon) {
        Link storage k = _links[poolOf[token]];
        return (k.cfg, k.beacon);
    }

    function _check(Link storage k) internal view returns (bool open, uint256 ath, uint256 unlocksAt) {
        ath = IBeaconModule(k.beacon).athUsd(k.cfg.beaconToken);
        unlocksAt = uint256(k.launchedAt) + k.cfg.maxLock;
        open = ath >= uint256(k.cfg.targetUsd) * 1e18 || block.timestamp >= unlocksAt;
    }
}
