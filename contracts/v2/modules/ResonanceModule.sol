// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {ModuleMath, TxTally} from "./lib/ModuleMath.sol";

/// @title ResonanceModule
/// @notice Momentum's damped oscillator, but it rewards rhythm: buys that land on the beat pump it far more
///   than buys off the beat.
///   cap = max(floor, base · (1 + x)),  x(t) = D(s) · (a·cos(2πs/beat) + b·sin(2πs/beat)),  s = t − t0,
///   D(s) = (1 − damping)^s (same math, tables and rebasing as MomentumModule). The swing's phase is the angle
///   of the phasor (a, b): 0 at a positive peak of x (the cap at its widest).
///   - On the beat: the phasor is within `windowBps` of a period from a peak (|angle| <= 2π · windowBps / 1e4,
///     x > 0). Such a buy pushes in phase: the swing's radius grows by energyOnBeat · amount / base.
///   - Off the beat: the push is energyOffBeat · amount / base, also in phase (a mistimed push still adds a
///     little, never more than an on-beat one).
///   - From rest (no swing) a buy starts it like Momentum: it kicks the sine term with energyOnBeat, so the
///     first peak, the first beat, comes a quarter period later; buying on every peak after that keeps
///     widening the cap. Coordinated rhythmic buying opens the cap far more than random buying.
///   - The radius is clamped to MAX_AMPLITUDE (3), so the cap stays within [floor, 4 · base]; the troughs widen
///     too, so between peaks the cap drops (down to the floor).
///   - Per transaction, like Momentum: all buys of one transaction together (tokens received) must fit, every
///     route counts (curve, router, aggregators). The cap is fixed at the first buy of each second (stored), so a
///     push only widens it from the next second: split swaps or same-second transactions can't ramp it. Sells are never capped and don't move the oscillator.
///   Gas: one O(log s) power, a few table lookups, one sqrt and one storage write per buy (~20k).
contract ResonanceModule is HookModuleBase, TxTally {
    struct Config {
        uint16 baseBps; // resting cap per buy, of the 1B supply: 0.1% .. 10%
        uint16 floorBps; // the cap never drops below this: 0.01% .. base
        uint32 beat; // seconds per swing (natural period): 10 s .. 1 day
        uint16 dampingBps; // share of the swing lost per second: 0.01% .. 50%
        uint16 energyOnBeatBps; // push of a base-sized buy on the beat, as a share of base: 0.01% .. 100%
        uint16 energyOffBeatBps; // push of a base-sized buy off the beat: 0 .. energyOnBeat
        uint16 windowBps; // half-width of the beat window, as a share of the period: 1 .. 2,500 (a quarter)
    }

    struct Osc {
        Config cfg; // 16 bytes
        int96 a; // cosine term, WAD
        int96 b; // sine term, WAD
        uint40 t0; // time the terms refer to
        address token;
        bool registered;
        uint40 capAt; // second the cap below was fixed in
        uint96 capVal; // the cap for every buy in second `capAt` (<= 4 base < 2^96)
    }

    uint16 public constant MIN_BASE_BPS = 10;
    uint16 public constant MAX_BASE_BPS = 1_000;
    uint32 public constant MIN_PERIOD = 10;
    uint32 public constant MAX_PERIOD = 1 days;
    uint16 public constant MAX_DAMPING_BPS = 5_000;
    uint16 public constant MAX_WINDOW_BPS = 2_500;
    /// @dev Swing radius bound (WAD): the cap never exceeds 4 x base.
    int256 public constant MAX_AMPLITUDE = 3e18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DUST = 1e9;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.resonance.tx");

    mapping(PoolId => Osc) internal _osc;
    mapping(address => PoolId) public poolOf;

    event Pushed(address indexed token, uint256 amount, uint256 cap, bool onBeat, int256 a, int256 b);

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
        if (c.floorBps == 0 || c.floorBps > c.baseBps) revert BadConfig();
        if (c.beat < MIN_PERIOD || c.beat > MAX_PERIOD) revert BadConfig();
        if (c.dampingBps == 0 || c.dampingBps > MAX_DAMPING_BPS) revert BadConfig();
        if (c.energyOnBeatBps == 0 || c.energyOnBeatBps > BPS) revert BadConfig();
        if (c.energyOffBeatBps > c.energyOnBeatBps) revert BadConfig();
        if (c.windowBps == 0 || c.windowBps > MAX_WINDOW_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Osc storage o = _osc[id];
        if (o.registered) revert AlreadyRegistered();
        o.cfg = abi.decode(config, (Config));
        o.token = token;
        o.registered = true;
        poolOf[token] = id;
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return new Credit[](0);
        Osc storage o = _osc[ctx.poolId];
        Config memory c = o.cfg;
        (int256 a, int256 b) = _at(o, c, block.timestamp);
        uint256 base = (TOTAL_SUPPLY * c.baseBps) / BPS;
        // The cap is fixed at the first buy of each second: pushes (which move `a` at once) only widen it
        // from the next second, so neither split swaps in one transaction nor several transactions in the
        // same second can ramp it while it is being checked.
        uint256 cap;
        if (o.capAt == block.timestamp) {
            cap = o.capVal;
        } else {
            cap = _cap(c, base, a);
            o.capAt = uint40(block.timestamp);
            o.capVal = uint96(cap);
        }
        uint256 bought = _tallyAdd(keccak256(abi.encode(TALLY, ctx.poolId)), ctx.amountOut);
        if (bought > cap) revert BuyCapExceeded(bought, cap);
        // amount <= cap <= 4 base, so k <= 4e18
        uint256 r = Math.sqrt(uint256(a * a) + uint256(b * b));
        bool beat = r == 0 || _onBeat(c, a, b);
        int256 k = int256(((beat ? c.energyOnBeatBps : c.energyOffBeatBps) * ctx.amountOut * WAD) / (BPS * base));
        if (r == 0) {
            b = k; // start the swing: peak (first beat) a quarter period later
        } else {
            // in-phase push: grow the radius by k along the current phasor
            a += (a * k) / int256(r);
            b += (b * k) / int256(r);
        }
        (a, b) = _clamp(a, b);
        o.a = int96(a);
        o.b = int96(b);
        o.t0 = uint40(block.timestamp);
        emit Pushed(o.token, ctx.amountOut, cap, beat, a, b);
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Largest buy (tokens received, whole transaction) accepted right now.
    function currentCap(address token) public view returns (uint256) {
        Osc storage o = _osc[poolOf[token]];
        if (o.capAt == block.timestamp) return o.capVal;
        Config memory c = o.cfg;
        (int256 a,) = _at(o, c, block.timestamp);
        return _cap(c, (TOTAL_SUPPLY * c.baseBps) / BPS, a);
    }

    /// @notice The cap `dt` seconds from now if nobody buys meanwhile (for the UI's chart).
    function capIn(address token, uint256 dt) external view returns (uint256) {
        if (dt == 0) return currentCap(token);
        Osc storage o = _osc[poolOf[token]];
        Config memory c = o.cfg;
        (int256 a,) = _at(o, c, block.timestamp + dt);
        return _cap(c, (TOTAL_SUPPLY * c.baseBps) / BPS, a);
    }

    /// @notice Whether a buy now would count as on the beat (true at rest: the first buy starts the beat).
    function onBeatNow(address token) external view returns (bool) {
        Osc storage o = _osc[poolOf[token]];
        Config memory c = o.cfg;
        (int256 a, int256 b) = _at(o, c, block.timestamp);
        return (a == 0 && b == 0) || _onBeat(c, a, b);
    }

    /// @notice Seconds until the next peak of the swing (0 at rest or right on a peak), for a "next beat" clock.
    function nextBeatIn(address token) external view returns (uint256) {
        Osc storage o = _osc[poolOf[token]];
        Config memory c = o.cfg;
        (int256 a, int256 b) = _at(o, c, block.timestamp);
        if (a == 0 && b == 0) return 0;
        // x(s) peaks when the phasor has rotated back to angle 0; scan the period at 1/64 resolution
        uint256 best;
        int256 top = type(int256).min;
        for (uint256 i; i < 64; ++i) {
            uint256 turn = (i * WAD) / 64;
            int256 v = (a * ModuleMath.cosTurn(turn) + b * ModuleMath.sinTurn(turn)) / int256(WAD);
            if (v > top) (top, best) = (v, i);
        }
        return (best * c.beat) / 64;
    }

    function state(address token) external view returns (int256 a, int256 b) {
        Osc storage o = _osc[poolOf[token]];
        return _at(o, o.cfg, block.timestamp);
    }

    function configOf(address token) external view returns (Config memory) {
        return _osc[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Phasor angle within ±2π·windowBps/1e4 of 0: a > 0 and |b|·cos(w) <= a·sin(w).
    function _onBeat(Config memory c, int256 a, int256 b) internal pure returns (bool) {
        if (a <= 0) return false;
        uint256 w = (uint256(c.windowBps) * WAD) / BPS; // turns
        int256 sw = ModuleMath.sinTurn(w);
        int256 cw = ModuleMath.cosTurn(w);
        int256 ab = b < 0 ? -b : b;
        return ab * cw <= a * sw;
    }

    /// @dev Rotates and damps the stored terms forward to time `t` (MomentumModule._at).
    function _at(Osc storage o, Config memory c, uint256 t) internal view returns (int256 a, int256 b) {
        a = o.a;
        b = o.b;
        if (a == 0 && b == 0) return (0, 0);
        uint256 t0 = o.t0;
        uint256 s = t > t0 ? t - t0 : 0;
        if (s == 0) return (a, b);
        uint256 d = ModuleMath.rpow(WAD - uint256(c.dampingBps) * 1e14, s);
        if (d < DUST) return (0, 0);
        uint256 turn = ((s % c.beat) * WAD) / c.beat;
        int256 cs = ModuleMath.cosTurn(turn);
        int256 sn = ModuleMath.sinTurn(turn);
        int256 dd = int256(d);
        int256 na = (((a * cs + b * sn) / int256(WAD)) * dd) / int256(WAD);
        int256 nb = (((b * cs - a * sn) / int256(WAD)) * dd) / int256(WAD);
        return (na, nb);
    }

    function _cap(Config memory c, uint256 base, int256 x) internal pure returns (uint256 cap) {
        if (x > MAX_AMPLITUDE) x = MAX_AMPLITUDE;
        int256 m = int256(WAD) + x;
        cap = m <= 0 ? 0 : (base * uint256(m)) / WAD;
        uint256 floor = (TOTAL_SUPPLY * c.floorBps) / BPS;
        if (cap < floor) cap = floor;
    }

    function _clamp(int256 a, int256 b) internal pure returns (int256, int256) {
        uint256 r = Math.sqrt(uint256(a * a) + uint256(b * b));
        if (r <= uint256(MAX_AMPLITUDE)) return (a, b);
        return ((a * MAX_AMPLITUDE) / int256(r), (b * MAX_AMPLITUDE) / int256(r));
    }
}
