// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookLaunchpadV2} from "./HookLaunchpadV2.sol";
import {AvaxHookV2} from "./AvaxHookV2.sol";
import {HookTokenV2} from "./HookTokenV2.sol";

/// @title HookLensV2
/// @notice Helpers for the frontend: curve quotes with module cuts (math mirrors HookLaunchpadV2; the
///         modules run in the hook's reverting dry run, so the quotes are eth_call only), a board page and
///         each launch's frozen module list.
contract HookLensV2 {
    HookLaunchpadV2 public immutable launchpad;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant PROTOCOL_FEE_BPS = 30;
    uint256 internal constant PIPS = 1_000_000;
    uint16 internal constant AFTER = 1 << 1; // ModuleCaps.AFTER_SWAP
    uint16 internal constant SWAP = 3; // BEFORE_SWAP | AFTER_SWAP

    struct LaunchView {
        address token;
        string name;
        string symbol;
        string image;
        address creator;
        address quote;
        uint64 createdAt;
        uint128 reserve;
        uint128 target;
        uint128 tokensSold;
        uint256 priceWei;
        bool graduated;
        address[] modules;
    }

    constructor(HookLaunchpadV2 _launchpad) {
        launchpad = _launchpad;
    }

    /// @notice A curve quote with the pool's modules applied (they run in a dry run that always reverts,
    ///         see AvaxHookV2.simulateCurve). Not a view: call it with eth_call (viem `simulateContract`).
    struct Quote {
        uint256 out; // what the trader receives after every cut (tokens on buys, quote on sells)
        uint256 used; // buys: quote spent (the rest is refunded); sells: tokens sold
        uint256 inCut; // module credits from the input (quote on buys, tokens on sells)
        uint256 outCut; // module credits from the output (tokens on buys, quote on sells)
        uint256 extraFee; // modules' extra fee, quote
        bool wouldRevert; // a module (or the curve guard) refuses this trade
        bytes reason; // its revert data
    }

    /// @notice Curve buy quote for `trader` with every module's cut, fee and refusal. Transfer rules
    ///         (onTransfer, e.g. max per wallet) are not simulated: eth_call the real trade for those.
    function quoteBuy(address token, uint256 amountIn, address trader) external returns (Quote memory q) {
        HookLaunchpadV2.Launch memory l = launchpad.getLaunch(token);
        if (l.complete || amountIn == 0) return q;
        bool guard = l.guardEndBlock != 0 && block.number < l.guardEndBlock;
        uint256 keepBps = BPS - PROTOCOL_FEE_BPS - l.creatorFeeBps - (guard ? l.snipeTaxBps : 0);
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        uint256 remaining = CURVE_SUPPLY - l.tokensSold;
        uint256 used = amountIn;
        bool last = _out(x, y, (amountIn * keepBps) / BPS) >= remaining;
        if (last) {
            uint256 netNeeded = Math.mulDiv(x, remaining, y - remaining, Math.Rounding.Ceil);
            used = Math.min(amountIn, Math.mulDiv(netNeeded, BPS, keepBps, Math.Rounding.Ceil));
        }
        AvaxHookV2.CurveTrade[] memory ts = new AvaxHookV2.CurveTrade[](l.caps & AFTER != 0 ? 2 : 1);
        ts[0] = _t(token, l.quote, trader, true, true, used, 0, x, y);
        AvaxHookV2.ModuleCuts[] memory c;
        if (l.caps & SWAP != 0) {
            (c, q.reason) = _sim(_first(ts));
            if (q.reason.length > 0) {
                q.wouldRevert = true;
                return q;
            }
        }
        uint256 take = c.length > 0 ? c[0].cut + (used * c[0].extraFeePips) / PIPS : 0;
        if (c.length > 0) (q.inCut, q.extraFee) = (c[0].cut, take - c[0].cut);
        q.used = used;
        if (last && take > 0) q.used = Math.min(amountIn, used + Math.mulDiv(take, BPS, keepBps, Math.Rounding.Ceil));
        uint256 net = (q.used * keepBps) / BPS - take;
        uint256 out = Math.min(_out(x, y, net), remaining);
        q.out = out;
        if (ts.length == 2) {
            ts[1] = _t(token, l.quote, trader, true, false, used, out, x + net, y - out);
            (c, q.reason) = _sim(ts);
            if (q.reason.length > 0) {
                q.wouldRevert = true;
                return q;
            }
            q.outCut = c[1].cut;
            q.out = out - c[1].cut;
        }
        if (guard && l.maxBuyPerBlock != 0) {
            uint256 total = (l.guardBlock == block.number ? l.guardSpent : 0) + q.used;
            if (total > l.maxBuyPerBlock) {
                q.wouldRevert = true;
                q.reason = abi.encodeWithSelector(HookLaunchpadV2.MaxBuyExceeded.selector, total, l.maxBuyPerBlock);
            }
        }
    }

    /// @notice Curve sell quote for `trader` with every module's cut, fee and refusal (see quoteBuy).
    function quoteSell(address token, uint256 tokenAmount, address trader) external returns (Quote memory q) {
        HookLaunchpadV2.Launch memory l = launchpad.getLaunch(token);
        if (l.complete || tokenAmount == 0 || tokenAmount > l.tokensSold) return q;
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        q.used = tokenAmount;
        AvaxHookV2.CurveTrade[] memory ts = new AvaxHookV2.CurveTrade[](l.caps & AFTER != 0 ? 2 : 1);
        ts[0] = _t(token, l.quote, trader, false, true, tokenAmount, 0, x, y);
        AvaxHookV2.ModuleCuts[] memory c;
        uint256 pips;
        if (l.caps & SWAP != 0) {
            (c, q.reason) = _sim(_first(ts));
            if (q.reason.length > 0) {
                q.wouldRevert = true;
                return q;
            }
            (q.inCut, pips) = (c[0].cut, c[0].extraFeePips);
        }
        uint256 sold = tokenAmount - q.inCut;
        uint256 gross = Math.min(Math.mulDiv(x, sold, y + sold), l.reserve);
        q.extraFee = (gross * pips) / PIPS;
        q.out = gross - (gross * PROTOCOL_FEE_BPS) / BPS - (gross * l.creatorFeeBps) / BPS - q.extraFee;
        if (ts.length == 2) {
            ts[1] = _t(token, l.quote, trader, false, false, tokenAmount, gross, x - gross, y + sold);
            (c, q.reason) = _sim(ts);
            if (q.reason.length > 0) {
                q.wouldRevert = true;
                return q;
            }
            q.outCut = c[1].cut;
            q.out -= c[1].cut;
        }
    }

    function _out(uint256 x, uint256 y, uint256 net) internal pure returns (uint256) {
        return Math.mulDiv(y, net, x + net);
    }

    function _t(address token, address quote, address trader, bool isBuy, bool before, uint256 amountIn, uint256 amountOut, uint256 x, uint256 y)
        internal
        view
        returns (AvaxHookV2.CurveTrade memory)
    {
        return AvaxHookV2.CurveTrade(
            token, quote, trader, trader, isBuy, before, amountIn, amountOut, launchpad.curveSqrtPrice(quote, token, x, y), ""
        );
    }

    function _first(AvaxHookV2.CurveTrade[] memory ts) internal pure returns (AvaxHookV2.CurveTrade[] memory one) {
        one = new AvaxHookV2.CurveTrade[](1);
        one[0] = ts[0];
    }

    /// @dev Runs the hook's dry run; returns the cuts, or the refusing module's revert data.
    function _sim(AvaxHookV2.CurveTrade[] memory ts) internal returns (AvaxHookV2.ModuleCuts[] memory cuts, bytes memory reason) {
        try launchpad.hook().simulateCurve(ts) {}
        catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == AvaxHookV2.CurveSimulation.selector) {
                assembly ("memory-safe") {
                    let len := mload(err)
                    err := add(err, 4)
                    mstore(err, sub(len, 4))
                }
                cuts = abi.decode(err, (AvaxHookV2.ModuleCuts[]));
            } else {
                reason = err.length == 0 ? bytes(hex"00") : err;
            }
        }
    }

    /// @notice The launch's module addresses and capabilities, in dispatch order.
    function modulesOf(address token) public view returns (address[] memory modules, uint16[] memory caps) {
        AvaxHookV2.PoolView memory v = launchpad.hook().poolInfo(launchpad.poolId(token));
        return (v.modules, v.moduleCaps);
    }

    /// @notice Newest-first page of launches for the board.
    function launchesPage(uint256 offset, uint256 limit) external view returns (LaunchView[] memory page) {
        uint256 n = launchpad.launchCount();
        if (offset >= n) return page;
        uint256 count = Math.min(limit, n - offset);
        page = new LaunchView[](count);
        for (uint256 i; i < count; ++i) {
            address t = launchpad.tokens(n - 1 - offset - i);
            HookLaunchpadV2.Launch memory l = launchpad.getLaunch(t);
            HookTokenV2 ht = HookTokenV2(t);
            (address[] memory mods,) = modulesOf(t);
            page[i] = LaunchView({
                token: t,
                name: ht.name(),
                symbol: ht.symbol(),
                image: ht.image(),
                creator: l.creator,
                quote: l.quote,
                createdAt: l.createdAt,
                reserve: l.graduated ? l.target : l.reserve,
                target: l.target,
                tokensSold: l.graduated ? uint128(CURVE_SUPPLY) : l.tokensSold,
                priceWei: _spot(l),
                graduated: l.graduated,
                modules: mods
            });
        }
    }

    function _spot(HookLaunchpadV2.Launch memory l) internal pure returns (uint256) {
        if (l.complete) return Math.mulDiv(uint256(l.virtualQuote) + l.target, 1e36, uint256(l.virtualTokens) - CURVE_SUPPLY);
        return Math.mulDiv(uint256(l.virtualQuote) + l.reserve, 1e36, uint256(l.virtualTokens) - l.tokensSold);
    }
}
