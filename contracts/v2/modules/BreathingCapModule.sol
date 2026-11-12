// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {ModuleMath, TxTally} from "./lib/ModuleMath.sol";

/// @title BreathingCapModule
/// @notice The per-buy cap breathes in and out on a fixed clock:
///   cap(t) = max(floor, base · (1 + swing · sin(2π · (t − launch) / cycle))).
///   It starts at base at launch, peaks a quarter cycle later and bottoms out three quarters in.
///   - Every buy counts (curve or pool, router or not); all buys of one transaction together (tokens received) must
///     fit under the cap. Sells are never capped. Curve buys are capped too (the breath starts at launch).
///   - Stateless: nothing is written per trade (sin comes from a 64-step quarter-wave table).
contract BreathingCapModule is HookModuleBase, TxTally {
    struct Config {
        uint16 baseBps; // average cap per buy, of the 1B supply: 0.1% .. 10%
        uint16 swingBps; // amplitude as a share of base: 1% .. 100%
        uint16 floorBps; // the cap never drops below this: 0.01% .. base
        uint32 cycle; // seconds per full breath: 1 min .. 7 days
    }

    struct Rule {
        Config cfg;
        uint64 launchedAt; // the breath's phase origin
        bool registered;
    }

    uint16 public constant MIN_BASE_BPS = 10;
    uint16 public constant MAX_BASE_BPS = 1_000;
    uint16 public constant MIN_SWING_BPS = 100;
    uint32 public constant MIN_CYCLE = 60;
    uint32 public constant MAX_CYCLE = 7 days;
    uint256 internal constant WAD = 1e18;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.breathing.tx");

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    error BuyCapExceeded(uint256 bought, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.AFTER_SWAP;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_BUY_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.baseBps < MIN_BASE_BPS || c.baseBps > MAX_BASE_BPS) revert BadConfig();
        if (c.swingBps < MIN_SWING_BPS || c.swingBps > BPS) revert BadConfig();
        if (c.floorBps == 0 || c.floorBps > c.baseBps) revert BadConfig();
        if (c.cycle < MIN_CYCLE || c.cycle > MAX_CYCLE) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.launchedAt = uint64(block.timestamp);
        r.registered = true;
        poolOf[token] = id;
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return new Credit[](0);
        Rule storage r = _rules[ctx.poolId];
        uint256 cap = _capAt(r.cfg, r.launchedAt, block.timestamp);
        uint256 bought = _tallyAdd(keccak256(abi.encode(TALLY, ctx.poolId)), ctx.amountOut);
        if (bought > cap) revert BuyCapExceeded(bought, cap);
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Largest buy (tokens received, whole transaction) accepted at time `ts`.
    function capAt(address token, uint256 ts) public view returns (uint256) {
        Rule storage r = _rules[poolOf[token]];
        return _capAt(r.cfg, r.launchedAt, ts);
    }

    function currentCap(address token) external view returns (uint256) {
        return capAt(token, block.timestamp);
    }

    function configOf(address token) external view returns (Config memory) {
        return _rules[poolOf[token]].cfg;
    }

    function _capAt(Config memory c, uint256 opened, uint256 ts) internal pure returns (uint256 cap) {
        uint256 s = ts > opened ? ts - opened : 0;
        uint256 turn = ((s % c.cycle) * WAD) / c.cycle;
        int256 m = int256(WAD) + (ModuleMath.sinTurn(turn) * int256(uint256(c.swingBps))) / int256(BPS);
        uint256 base = (TOTAL_SUPPLY * c.baseBps) / BPS;
        cap = m <= 0 ? 0 : (base * uint256(m)) / WAD;
        uint256 floor = (TOTAL_SUPPLY * c.floorBps) / BPS;
        if (cap < floor) cap = floor;
    }
}
