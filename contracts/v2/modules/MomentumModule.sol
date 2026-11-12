// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {ModuleMath, TxTally} from "./lib/ModuleMath.sol";

/// @title MomentumModule
/// @notice The per-buy cap rides a damped oscillator that every buy kicks.
///   cap = max(floor, base · (1 + x)),  x(t) = D(s) · (a·cos(2πs/period) + b·sin(2πs/period)),  s = t − t0,
///   D(s) = (1 − damping)^s (damping per second). A buy of `amount` tokens adds energy · amount / base to
///   the sine term: right after a buy the cap swells, peaks a quarter period later, swings below base half a
///   period later, and the swing fades with the damping. The state is rebased (rotated and damped) at each
///   buy, so x is continuous; the swing's radius sqrt(a² + b²) is clamped to MAX_AMPLITUDE, so the cap
///   stays within [floor, base · (1 + MAX_AMPLITUDE)].
///   - Every buy counts (curve or pool, router or not). The cap applies per transaction: all buys of one transaction
///     together (tokens received) must fit, so splitting a buy into several swaps doesn't help, and a buy's
///     own kick only shows up from the next second: the cap is fixed at the first buy of each second (the
///     radius clamp would otherwise rescale the cosine term, and so the cap, in the same second).
///   - Sells are never capped and don't move the oscillator. Curve buys are capped and kick it too.
///   Gas: one O(log s) power, two table lookups and one storage write per buy (~15k).
contract MomentumModule is HookModuleBase, TxTally {
    struct Config {
        uint16 baseBps; // resting cap per buy, of the 1B supply: 0.1% .. 10%
        uint16 floorBps; // the cap never drops below this: 0.01% .. base
        uint32 period; // seconds per swing: 10 s .. 1 day
        uint16 dampingBps; // share of the swing lost per second: 0.01% .. 50%
        uint16 energyBps; // kick of a base-sized buy, as a share of base: 0.01% .. 100%
    }

    struct Osc {
        Config cfg; // 12 bytes
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
    /// @dev Swing radius bound (WAD): the cap never exceeds 4 x base.
    int256 public constant MAX_AMPLITUDE = 3e18;
    uint256 internal constant WAD = 1e18;
    /// @dev Below this decay factor the swing is gone (and longer gaps need no power computation).
    uint256 internal constant DUST = 1e9;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.momentum.tx");

    mapping(PoolId => Osc) internal _osc;
    mapping(address => PoolId) public poolOf;

    event Kicked(address indexed token, uint256 amount, uint256 cap, int256 a, int256 b);

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
        if (c.period < MIN_PERIOD || c.period > MAX_PERIOD) revert BadConfig();
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
        (int256 a, int256 b) = _now(o, c);
        uint256 base = (TOTAL_SUPPLY * c.baseBps) / BPS;
        // The cap is fixed at the first buy of each second: a kick (and the radius clamp, which rescales the
        // cosine term too) only moves it from the next second, so no buy can shrink or grow the cap seen by
        // later buys in the same second.
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
        // kick: energy · amount / base on the sine term (amount <= cap < 4 base, so no overflow)
        b += int256((uint256(c.energyBps) * ctx.amountOut * WAD) / (BPS * base));
        (a, b) = _clamp(a, b);
        o.a = int96(a);
        o.b = int96(b);
        o.t0 = uint40(block.timestamp);
        emit Kicked(o.token, ctx.amountOut, cap, a, b);
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Largest buy (tokens received, whole transaction) accepted right now.
    function currentCap(address token) public view returns (uint256) {
        Osc storage o = _osc[poolOf[token]];
        if (o.capAt == block.timestamp) return o.capVal;
        Config memory c = o.cfg;
        (int256 a,) = _now(o, c);
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

    /// @return a the cosine term now (WAD); the swing x is `a` at this instant
    /// @return b the sine term now (WAD)
    function state(address token) external view returns (int256 a, int256 b) {
        Osc storage o = _osc[poolOf[token]];
        return _now(o, o.cfg);
    }

    function configOf(address token) external view returns (Config memory) {
        return _osc[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    function _now(Osc storage o, Config memory c) internal view returns (int256, int256) {
        return _at(o, c, block.timestamp);
    }

    /// @dev Rotates and damps the stored terms forward to time `t`.
    function _at(Osc storage o, Config memory c, uint256 t) internal view returns (int256 a, int256 b) {
        a = o.a;
        b = o.b;
        if (a == 0 && b == 0) return (0, 0);
        uint256 t0 = o.t0;
        uint256 s = t > t0 ? t - t0 : 0;
        if (s == 0) return (a, b);
        uint256 d = ModuleMath.rpow(WAD - uint256(c.dampingBps) * 1e14, s);
        if (d < DUST) return (0, 0);
        uint256 turn = ((s % c.period) * WAD) / c.period;
        int256 cs = ModuleMath.cosTurn(turn);
        int256 sn = ModuleMath.sinTurn(turn);
        int256 dd = int256(d);
        int256 na = (((a * cs + b * sn) / int256(WAD)) * dd) / int256(WAD);
        int256 nb = (((b * cs - a * sn) / int256(WAD)) * dd) / int256(WAD);
        return (na, nb);
    }

    function _cap(Config memory c, uint256 base, int256 x) internal pure returns (uint256 cap) {
        if (x > MAX_AMPLITUDE) x = MAX_AMPLITUDE; // (table rounding can't push it past the bound)
        int256 m = int256(WAD) + x;
        cap = m <= 0 ? 0 : (base * uint256(m)) / WAD;
        uint256 floor = (TOTAL_SUPPLY * c.floorBps) / BPS;
        if (cap < floor) cap = floor;
    }

    /// @dev Scales (a, b) down to radius MAX_AMPLITUDE. Rotation keeps the radius and damping shrinks it,
    ///      so |x| <= radius <= MAX_AMPLITUDE at every later time.
    function _clamp(int256 a, int256 b) internal pure returns (int256, int256) {
        uint256 r = Math.sqrt(uint256(a * a) + uint256(b * b)); // |a|, |b| < 2^100: no overflow
        if (r <= uint256(MAX_AMPLITUDE)) return (a, b);
        return ((a * MAX_AMPLITUDE) / int256(r), (b * MAX_AMPLITUDE) / int256(r));
    }
}
