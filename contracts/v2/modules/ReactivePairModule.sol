// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title ReactivePairModule
/// @notice Two tokens linked at launch react to each other: buying one widens the other's per-buy cap, selling
///   one narrows it.
///   - Linking: the second token's config names `partner`, a token already launched with this module by the SAME
///     creator that has no partner yet; the link is mutual and frozen. A token launched with partner = 0 is
///     unlinked (plain base cap) until a later launch of its creator links to it. Nobody else can link to it.
///   - Each token tracks a decaying net flow: tokens bought minus tokens sold (every route: curve, router,
///     aggregators), halving every `halfLife` seconds. Flow is measured in the token's own units (share of its
///     1B supply), never in quote, so a pair with different quote assets (AVAX and USDC, say) compares fairly.
///   - A token's cap per buy = base · (1 + sensitivity · partnerNetFlow / scale), clamped to [floor, ceil] of
///     supply. `scale` is the partner net flow (share of supply) that moves the cap by `sensitivity`.
///   - Per transaction, like Momentum: all buys of one transaction together (tokens received) must fit.
///     Sells are never capped (the module ignores them except to book their flow; it's isolated on sells).
///   - The partner's flow is easy to push: buying the partner (and later selling it) widens this token's cap for
///     a while. The ceiling bounds what that buys you.
///   Decay: whole halvings by shifting, linear in between (at most ~6% above an exact exponential).
///   Gas: two flow reads (one per token) and one storage write per trade (~12k).
contract ReactivePairModule is HookModuleBase, TxTally {
    struct Config {
        uint16 baseBps; // cap per buy with a neutral partner, of the 1B supply: 0.1% .. 10%
        uint16 floorBps; // lowest cap: 0.01% .. base
        uint16 ceilBps; // highest cap: base .. 20%
        uint32 sensitivityBps; // cap change per `scale` of partner flow, as a share of base: 0.01% .. 1,000%
        uint16 scaleBps; // partner net flow (of supply) that moves the cap by `sensitivity`: 0.01% .. 50%
        uint32 halfLife; // seconds for the net flow to halve: 1 min .. 7 days
        address partner; // a token of the same creator already on this module without a partner, or 0
    }

    struct Pair {
        Config cfg;
        address creator;
        address token;
        address partner; // linked token (mutual), or 0
        bool registered;
        int128 flow; // net flow at t0, tokens (18 decimals), within ±TOTAL_SUPPLY
        uint40 t0;
    }

    uint16 public constant MIN_BASE_BPS = 10;
    uint16 public constant MAX_BASE_BPS = 1_000;
    uint16 public constant MAX_CEIL_BPS = 2_000;
    uint32 public constant MAX_SENSITIVITY_BPS = 100_000;
    uint16 public constant MAX_SCALE_BPS = 5_000;
    uint32 public constant MIN_HALF_LIFE = 1 minutes;
    uint32 public constant MAX_HALF_LIFE = 7 days;
    uint256 internal constant WAD = 1e18;
    bytes32 internal constant TALLY = keccak256("avaxhook.v2.reactivepair.tx");

    mapping(PoolId => Pair) internal _pairs;
    mapping(address => PoolId) public poolOf;

    event Linked(address indexed token, address indexed partner);
    event Flow(address indexed token, int256 flow);

    error BuyCapExceeded(uint256 bought, uint256 cap);
    error BadPartner();

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
        if (c.ceilBps < c.baseBps || c.ceilBps > MAX_CEIL_BPS) revert BadConfig();
        if (c.sensitivityBps == 0 || c.sensitivityBps > MAX_SENSITIVITY_BPS) revert BadConfig();
        if (c.scaleBps == 0 || c.scaleBps > MAX_SCALE_BPS) revert BadConfig();
        if (c.halfLife < MIN_HALF_LIFE || c.halfLife > MAX_HALF_LIFE) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address creator, bytes calldata config)
        external
        override
        onlyHook
    {
        Pair storage p = _pairs[id];
        if (p.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        p.cfg = c;
        p.creator = creator;
        p.token = token;
        p.registered = true;
        p.t0 = uint40(block.timestamp);
        poolOf[token] = id;
        if (c.partner != address(0)) {
            if (c.partner == token) revert BadPartner();
            Pair storage q = _pairs[poolOf[c.partner]];
            if (!q.registered || q.token != c.partner || q.creator != creator || q.partner != address(0)) {
                revert BadPartner();
            }
            p.partner = c.partner;
            q.partner = token;
            emit Linked(token, c.partner);
            emit Linked(c.partner, token);
        }
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        Pair storage p = _pairs[ctx.poolId];
        int256 f = _flowNow(p);
        if (ctx.isBuy) {
            uint256 cap = _capOf(p);
            uint256 bought = _tallyAdd(keccak256(abi.encode(TALLY, ctx.poolId)), ctx.amountOut);
            if (bought > cap) revert BuyCapExceeded(bought, cap);
            f += int256(ctx.amountOut);
        } else {
            f -= int256(ctx.amountIn);
        }
        int256 lim = int256(TOTAL_SUPPLY);
        if (f > lim) f = lim;
        if (f < -lim) f = -lim;
        p.flow = int128(f);
        p.t0 = uint40(block.timestamp);
        emit Flow(p.token, f);
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Largest buy (tokens received, whole transaction) accepted right now.
    function currentCap(address token) external view returns (uint256) {
        return _capOf(_pairs[poolOf[token]]);
    }

    /// @notice The token's decayed net flow now (tokens bought minus sold, 18 decimals; negative = net selling).
    function netFlow(address token) public view returns (int256) {
        return _flowNow(_pairs[poolOf[token]]);
    }

    function partnerOf(address token) external view returns (address) {
        return _pairs[poolOf[token]].partner;
    }

    function configOf(address token) external view returns (Config memory) {
        return _pairs[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    function _capOf(Pair storage p) internal view returns (uint256 cap) {
        Config memory c = p.cfg;
        uint256 base = (TOTAL_SUPPLY * c.baseBps) / BPS;
        if (p.partner == address(0)) return base;
        int256 pf = _flowNow(_pairs[poolOf[p.partner]]);
        // multiplier = 1 + sensitivity · pf / scale (WAD); |pf| <= 1e27, so no overflow
        int256 scale = int256((TOTAL_SUPPLY * c.scaleBps) / BPS);
        int256 m = int256(WAD) + (int256(uint256(c.sensitivityBps)) * pf * int256(WAD)) / (int256(BPS) * scale);
        cap = m <= 0 ? 0 : (base * uint256(m)) / WAD;
        uint256 floor = (TOTAL_SUPPLY * c.floorBps) / BPS;
        uint256 ceil = (TOTAL_SUPPLY * c.ceilBps) / BPS;
        if (cap < floor) cap = floor;
        if (cap > ceil) cap = ceil;
    }

    /// @dev Flow decayed to now: halved per whole half-life, linear between halvings.
    function _flowNow(Pair storage p) internal view returns (int256) {
        int256 f = p.flow;
        if (f == 0) return 0;
        uint256 s = block.timestamp > p.t0 ? block.timestamp - p.t0 : 0;
        uint256 h = p.cfg.halfLife;
        uint256 n = s / h;
        if (n >= 100) return 0;
        bool neg = f < 0;
        uint256 v = uint256(neg ? -f : f) >> n;
        v -= (v * (s % h)) / (2 * h);
        return neg ? -int256(v) : int256(v);
    }
}
