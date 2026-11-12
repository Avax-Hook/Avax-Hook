// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {ModuleMath, TxTally} from "./lib/ModuleMath.sol";

/// @title CoupledResonatorModule
/// @notice The per-buy cap follows two coupled oscillators A and B: buys kick A, the swing flows over into B
///   and back, so the cap swells and fades in beats long after the buying stopped.
///   Model (coupled-mode equations with a quarter-period, gyroscopic coupling; complex amplitudes A and B,
///   frequencies in turns per second):
///     dA/dt = 2π·(i·fA·A − κ·B),   dB/dt = 2π·(i·fB·B + κ·A),   fA = 1/periodA, fB = 1/periodB,
///     κ = couplingBps · (fA + fB)/2 / 1e4,
///   with the closed-form solution (f̄ = (fA+fB)/2, δ = (fA−fB)/2, Ω = sqrt(κ² + δ²), θ = 2πΩs):
///     A(s) = D(s)·e^{i2πf̄s}·[(cos θ + i(δ/Ω) sin θ)·A0 − (κ/Ω) sin θ·B0]
///     B(s) = D(s)·e^{i2πf̄s}·[(κ/Ω) sin θ·A0 + (cos θ − i(δ/Ω) sin θ)·B0]
///   and damping D(s) = (1 − damping)^s. The evolution is energy-preserving apart from D (the generator is
///   Hermitian), so with equal periods the whole swing moves from A to B in periodA / (4 · coupling) and back;
///   with different periods only the share (κ/Ω)² of it does, faster. Because the coupling is a quarter period
///   out of phase, the summed swing Re(A + B) beats: after a kick of A its amplitude goes as
///   sqrt(1 + (κ/Ω)·sin 2θ) — it swells to sqrt(2) times the kick and fades to nothing (equal periods), over and
///   over, while damping slowly takes it all out. The state is rebased at each buy (O(1), no stepping).
///   cap = clamp(base · (1 + Re A + Re B), floor, 4 · base).
///   - A buy of `amount` tokens kicks A by energy · amount / base (on its sine term: right after a buy the cap
///     swells, like MomentumModule). The total radius sqrt(|A|² + |B|²) is clamped to MAX_RADIUS (2), so
///     |Re A + Re B| <= 2·sqrt(2) and the cap stays within [floor, 4 · base].
///   - Per transaction, like Momentum: all buys of one transaction together (tokens received) must fit; every
///     route counts (curve, router, aggregators). The cap is fixed at the first buy of each second, so a kick
///     (and the radius clamp, which rescales every term) only moves it from the next second. Sells are never capped and don't move the oscillators.
///   Gas: one O(log s) power, four table lookups, one sqrt and one storage write per buy (~25k).
contract CoupledResonatorModule is HookModuleBase, TxTally {
    struct Config {
        uint16 baseBps; // resting cap per buy, of the 1B supply: 0.1% .. 10%
        uint16 floorBps; // the cap never drops below this: 0.01% .. base
        uint32 periodA; // seconds per swing of A: 10 s .. 1 day
        uint32 periodB; // seconds per swing of B: 10 s .. 1 day
        uint16 couplingBps; // coupling as a share of the mean frequency: 0.01% .. 50%
        uint16 dampingBps; // share of the swing lost per second: 0.01% .. 50%
        uint16 energyBps; // kick of a base-sized buy, as a share of base: 0.01% .. 100%
    }

    /// @dev Complex amplitudes, WAD. |each| <= MAX_RADIUS (+ table rounding), so int64 holds them.
    struct Amp {
        int64 ar;
        int64 ai;
        int64 br;
        int64 bi;
    }

    struct Osc {
        Config cfg;
        uint40 t0; // time the amplitudes refer to
        bool registered;
        address token;
        Amp amp;
        uint40 capAt; // second the cap below was fixed in
        uint96 capVal; // the cap for every buy in second `capAt` (<= 4 base < 2^96)
    }

    uint16 public constant MIN_BASE_BPS = 10;
    uint16 public constant MAX_BASE_BPS = 1_000;
    uint32 public constant MIN_PERIOD = 10;
    uint32 public constant MAX_PERIOD = 1 days;
    uint16 public constant MAX_COUPLING_BPS = 5_000;
    uint16 public constant MAX_DAMPING_BPS = 5_000;
    /// @dev Bound on sqrt(|A|² + |B|²) (WAD).
    int256 public constant MAX_RADIUS = 2e18;
    int256 public constant MAX_SWING = 3e18;
    int256 internal constant WAD = 1e18;
    uint256 internal constant UWAD = 1e18;
    uint256 internal constant DUST = 1e9;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.coupled.tx");

    mapping(PoolId => Osc) internal _osc;
    mapping(address => PoolId) public poolOf;

    event Kicked(address indexed token, uint256 amount, uint256 cap, int256 ar, int256 ai, int256 br, int256 bi);

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
        if (c.periodA < MIN_PERIOD || c.periodA > MAX_PERIOD) revert BadConfig();
        if (c.periodB < MIN_PERIOD || c.periodB > MAX_PERIOD) revert BadConfig();
        if (c.couplingBps == 0 || c.couplingBps > MAX_COUPLING_BPS) revert BadConfig();
        if (c.dampingBps == 0 || c.dampingBps > MAX_DAMPING_BPS) revert BadConfig();
        if (c.energyBps == 0 || c.energyBps > BPS) revert BadConfig();
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
        int256[4] memory v = _at(o, c, block.timestamp);
        uint256 base = (TOTAL_SUPPLY * c.baseBps) / BPS;
        // fixed at the first buy of each second (see the contract notes)
        uint256 cap;
        if (o.capAt == block.timestamp) {
            cap = o.capVal;
        } else {
            cap = _cap(c, base, v[0] + v[2]);
            o.capAt = uint40(block.timestamp);
            o.capVal = uint96(cap);
        }
        uint256 bought = _tallyAdd(keccak256(abi.encode(TALLY, ctx.poolId)), ctx.amountOut);
        if (bought > cap) revert BuyCapExceeded(bought, cap);
        // kick A on its sine term: Re A(s) gains k·sin(2πfA s). amount <= cap <= 4 base, so k <= 4e18
        v[1] -= int256((uint256(c.energyBps) * ctx.amountOut * UWAD) / (BPS * base));
        v = _clamp(v);
        o.amp = Amp(int64(v[0]), int64(v[1]), int64(v[2]), int64(v[3]));
        o.t0 = uint40(block.timestamp);
        emit Kicked(o.token, ctx.amountOut, cap, v[0], v[1], v[2], v[3]);
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Largest buy (tokens received, whole transaction) accepted right now.
    function currentCap(address token) external view returns (uint256) {
        return capIn(token, 0);
    }

    /// @notice The cap `dt` seconds from now if nobody buys meanwhile (for the UI's chart).
    function capIn(address token, uint256 dt) public view returns (uint256) {
        Osc storage o = _osc[poolOf[token]];
        if (dt == 0 && o.capAt == block.timestamp) return o.capVal;
        Config memory c = o.cfg;
        int256[4] memory v = _at(o, c, block.timestamp + dt);
        return _cap(c, (TOTAL_SUPPLY * c.baseBps) / BPS, v[0] + v[2]);
    }

    /// @return ar Re A (A's share of the swing now), ai Im A, br Re B, bi Im B (WAD)
    function state(address token) external view returns (int256 ar, int256 ai, int256 br, int256 bi) {
        Osc storage o = _osc[poolOf[token]];
        int256[4] memory v = _at(o, o.cfg, block.timestamp);
        return (v[0], v[1], v[2], v[3]);
    }

    /// @notice Energy (|amplitude|², WAD) in each oscillator now: shows the swing moving between A and B.
    function energies(address token) external view returns (uint256 ea, uint256 eb) {
        Osc storage o = _osc[poolOf[token]];
        int256[4] memory v = _at(o, o.cfg, block.timestamp);
        ea = uint256(v[0] * v[0] + v[1] * v[1]) / UWAD;
        eb = uint256(v[2] * v[2] + v[3] * v[3]) / UWAD;
    }

    function configOf(address token) external view returns (Config memory) {
        return _osc[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Closed-form evolution of the stored amplitudes to time `t` (see the contract notes).
    function _at(Osc storage o, Config memory c, uint256 t) internal view returns (int256[4] memory v) {
        Amp memory m = o.amp;
        (v[0], v[1], v[2], v[3]) = (m.ar, m.ai, m.br, m.bi);
        if (m.ar == 0 && m.ai == 0 && m.br == 0 && m.bi == 0) return v;
        uint256 t0 = o.t0;
        uint256 s = t > t0 ? t - t0 : 0;
        if (s == 0) return v;
        uint256 d = ModuleMath.rpow(UWAD - uint256(c.dampingBps) * 1e14, s);
        if (d < DUST) return [int256(0), 0, 0, 0];

        // frequencies in turns per second (WAD)
        int256 fA = WAD / int256(uint256(c.periodA));
        int256 fB = WAD / int256(uint256(c.periodB));
        int256 fbar = (fA + fB) / 2;
        int256 delta = (fA - fB) / 2;
        int256 kappa = (fbar * int256(uint256(c.couplingBps))) / int256(BPS);
        int256 om = int256(Math.sqrt(uint256(kappa * kappa + delta * delta))); // WAD (kappa > 0)
        int256 p = (kappa * WAD) / om; // κ/Ω
        int256 q = (delta * WAD) / om; // δ/Ω

        uint256 tw = (uint256(om) * s) % UWAD;
        int256 cw = ModuleMath.cosTurn(tw);
        int256 sw = ModuleMath.sinTurn(tw);
        int256 qs = (q * sw) / WAD;
        int256 ps = (p * sw) / WAD;
        // [A; B] <- M · [A; B], M = [[cw + i qs, −ps], [ps, cw − i qs]]
        int256 ar = (cw * v[0] - qs * v[1] - ps * v[2]) / WAD;
        int256 ai = (cw * v[1] + qs * v[0] - ps * v[3]) / WAD;
        int256 br = (ps * v[0] + cw * v[2] + qs * v[3]) / WAD;
        int256 bi = (ps * v[1] + cw * v[3] - qs * v[2]) / WAD;

        // common rotation e^{i2πf̄s} and damping
        uint256 tb = (uint256(fbar) * s) % UWAD;
        int256 cb = (ModuleMath.cosTurn(tb) * int256(d)) / WAD;
        int256 sb = (ModuleMath.sinTurn(tb) * int256(d)) / WAD;
        v[0] = (ar * cb - ai * sb) / WAD;
        v[1] = (ar * sb + ai * cb) / WAD;
        v[2] = (br * cb - bi * sb) / WAD;
        v[3] = (br * sb + bi * cb) / WAD;
    }

    function _cap(Config memory c, uint256 base, int256 x) internal pure returns (uint256 cap) {
        if (x > MAX_SWING) x = MAX_SWING;
        int256 m = WAD + x;
        cap = m <= 0 ? 0 : (base * uint256(m)) / UWAD;
        uint256 floor = (TOTAL_SUPPLY * c.floorBps) / BPS;
        if (cap < floor) cap = floor;
    }

    /// @dev Scales all four terms down to total radius MAX_RADIUS. The evolution preserves the radius (up to
    ///      table rounding) and damping shrinks it, so the bound holds at every later time.
    function _clamp(int256[4] memory v) internal pure returns (int256[4] memory) {
        uint256 r = Math.sqrt(uint256(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]));
        if (r <= uint256(MAX_RADIUS)) return v;
        for (uint256 i; i < 4; ++i) {
            v[i] = (v[i] * MAX_RADIUS) / int256(r);
        }
        return v;
    }
}
