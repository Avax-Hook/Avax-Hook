// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title ReferralModule
/// @notice v1 "Referral". In v1 the referral was carved out of the creator fee, so a buyer paid the same with
///         or without a link. v2's core creator fee can't be split by a module, so this module charges its
///         own pool-phase creator fee (`feeBps`, on top of the core creator fee, together at most 10%) and
///         carves the referral out of it:
///   - every pool buy pays `feeBps` of its input and every pool sell `feeBps` of its output;
///   - on a router buy whose buyer has a bound referrer, `referralBps` of the input goes to the referrer and
///     the rest of `feeBps` to the creator; otherwise all of it goes to the creator.
///   Buyers pay the same with or without a referral. Sticky referrals (HK-7 / L-2): a buyer's first valid
///   referrer is bound for good (across every pool using this module) and later ones are ignored. A referrer
///   can't be the buyer, tx.origin, someone the buyer referred, or a protocol address (L-3: 0x0/0x1, 0x…dEaD,
///   the hook, launchpad, PoolManager, router, the pool's modules), and a bound referrer that is tx.origin
///   earns nothing on that trade. Only the trusted router names buyers and referrers.
///   Both phases: on the bonding curve the launchpad names the buyer and referrer (buyWithData).
contract ReferralModule is HookModuleBase {
    struct Config {
        uint16 feeBps; // pool-phase creator fee charged by this module, 1 .. 1,000 (with the core fee <= 1,000)
        uint16 referralBps; // carved out of feeBps on referred buys, 1 .. min(200, feeBps)
    }

    struct Rule {
        Config cfg;
        address creator;
        uint128 totalReferral;
    }

    uint16 public constant MAX_CREATOR_FEE_BPS = 1_000;
    uint16 public constant MAX_REFERRAL_BPS = 200;

    mapping(PoolId => Rule) internal _rules;
    /// @notice A buyer's referrer, bound by their first router buy that named a valid one; never changes.
    mapping(address => address) public referrerOf;

    event ReferrerBound(address indexed buyer, address indexed referrer);
    event ReferralPaid(PoolId indexed id, address indexed buyer, address indexed referrer, uint256 amount);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.feeBps == 0 || c.feeBps > MAX_CREATOR_FEE_BPS) revert BadConfig();
        if (c.referralBps == 0 || c.referralBps > MAX_REFERRAL_BPS || c.referralBps > c.feeBps) revert BadConfig();
    }

    /// @dev Core creator fee + this fee stay within v1's 10% creator-fee ceiling.
    function onRegister(PoolId id, address, address, address creator, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.creator != address(0)) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        if (uint256(AvaxHookV2(payable(hook)).poolInfo(id).creatorFeeBps) + c.feeBps > MAX_CREATOR_FEE_BPS) revert BadConfig();
        r.cfg = c;
        r.creator = creator;
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory credits) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        Rule storage r = _rules[ctx.poolId];
        Config memory c = r.cfg;
        uint256 fee = (ctx.amountIn * c.feeBps) / BPS;
        address ref = ctx.trader == address(0) ? address(0) : _bind(ctx.poolId, ctx.trader, ctx.referrer);
        uint256 refCut = ref == address(0) ? 0 : (ctx.amountIn * c.referralBps) / BPS;
        if (refCut > fee) refCut = fee;
        if (refCut == 0) return (0, fee == 0 ? new Credit[](0) : _one(r.creator, fee));
        r.totalReferral += uint128(refCut);
        emit ReferralPaid(ctx.poolId, ctx.trader, ref, refCut);
        credits = new Credit[](2);
        credits[0] = Credit(ref, refCut);
        credits[1] = Credit(r.creator, fee - refCut);
        return (0, credits);
    }

    function onAfterSwap(SwapContext calldata ctx) external view override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        Rule storage r = _rules[ctx.poolId];
        uint256 fee = (ctx.amountOut * r.cfg.feeBps) / BPS;
        return fee == 0 ? new Credit[](0) : _one(r.creator, fee);
    }

    /// @dev L-3: addresses that can never be a referrer (bound for good, they'd sink the referral cut):
    ///      0, LP_DONATE (0x1) and other precompile-low addresses, 0x…dEaD, the hook, the launchpad, the
    ///      PoolManager, the router and the pool's modules. Such a buy binds nothing (and isn't refused).
    function _protocolAddress(PoolId id, address a) internal view returns (bool) {
        if (uint160(a) <= uint160(ModuleCaps.LP_DONATE) || a == ModuleCaps.BURN || a == hook || a == address(poolManager)) {
            return true;
        }
        AvaxHookV2 h = AvaxHookV2(payable(hook));
        if (a == h.launchpad() || a == h.router()) return true;
        address[] memory mods = h.poolInfo(id).modules;
        for (uint256 i; i < mods.length; ++i) {
            if (mods[i] == a) return true;
        }
        return false;
    }

    function ruleOf(PoolId id) external view returns (Rule memory) {
        return _rules[id];
    }

    /// @dev Sticky binding (v1 `_bindReferrer`).
    function _bind(PoolId id, address buyer, address referrer) internal returns (address bound) {
        bound = referrerOf[buyer];
        if (bound == address(0)) {
            if (referrer == buyer || referrer == tx.origin || _protocolAddress(id, referrer) || referrerOf[referrer] == buyer) {
                return address(0);
            }
            referrerOf[buyer] = bound = referrer;
            emit ReferrerBound(buyer, referrer);
        }
        if (bound == tx.origin) bound = address(0);
    }
}
