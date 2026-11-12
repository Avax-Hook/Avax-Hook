// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookLaunchpad} from "./HookLaunchpad.sol";
import {HookToken} from "./HookToken.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";

/// @title HookLens
/// @notice Read-only helpers for the frontend: curve quotes, spot price and a board page.
///         Kept out of the launchpad so it stays under the contract size limit; the math mirrors
///         HookLaunchpad exactly.
contract HookLens {
    HookLaunchpad public immutable launchpad;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant PROTOCOL_FEE_BPS = 30;

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
        uint256 priceWei; // quote units per 1e18 tokens, scaled by 1e18 (curve price, or opening price once graduated)
        bool graduated;
    }

    constructor(HookLaunchpad _launchpad) {
        launchpad = _launchpad;
    }

    function quoteBuy(address token, uint256 amountIn) external view returns (uint256 tokensOut, uint256 used) {
        HookLaunchpad.Launch memory l = launchpad.getLaunch(token);
        if (l.complete) return (0, 0);
        bool guard = l.guardEndBlock != 0 && block.number < l.guardEndBlock;
        uint256 keepBps = BPS - PROTOCOL_FEE_BPS - l.hook.creatorFeeBps - (guard ? l.hook.snipeTaxBps : 0);
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        uint256 net = (amountIn * keepBps) / BPS;
        tokensOut = Math.mulDiv(y, net, x + net);
        used = amountIn;
        uint256 remaining = CURVE_SUPPLY - l.tokensSold;
        if (tokensOut >= remaining) {
            tokensOut = remaining;
            uint256 netNeeded = Math.mulDiv(x, remaining, y - remaining, Math.Rounding.Ceil);
            used = Math.min(amountIn, Math.mulDiv(netNeeded, BPS, keepBps, Math.Rounding.Ceil));
        }
    }

    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 out) {
        HookLaunchpad.Launch memory l = launchpad.getLaunch(token);
        if (l.complete || tokenAmount > l.tokensSold) return 0;
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        uint256 gross = Math.min(Math.mulDiv(x, tokenAmount, y + tokenAmount), l.reserve);
        out = gross - (gross * (PROTOCOL_FEE_BPS + l.hook.creatorFeeBps)) / BPS;
    }

    function spotPrice(address token) public view returns (uint256) {
        return _spot(launchpad.getLaunch(token));
    }

    /// @notice Newest-first page of launches for the board.
    function launchesPage(uint256 offset, uint256 limit) external view returns (LaunchView[] memory page) {
        uint256 n = launchpad.launchCount();
        if (offset >= n) return page;
        uint256 count = Math.min(limit, n - offset);
        page = new LaunchView[](count);
        for (uint256 i; i < count; ++i) {
            address t = launchpad.tokens(n - 1 - offset - i);
            HookLaunchpad.Launch memory l = launchpad.getLaunch(t);
            HookToken ht = HookToken(t);
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
                graduated: l.graduated
            });
        }
    }

    /// @notice Allowed quote assets with the raise a launch would need today, in quote units,
    ///         and the USD price used (18 decimals). Unreadable feeds report a zero target.
    function quoteAssets()
        external
        view
        returns (address[] memory assets, bool[] memory allowed, uint128[] memory targets, uint256[] memory usdPrices)
    {
        QuoteRegistry r = launchpad.registry();
        uint256 n = r.quoteCount();
        assets = new address[](n);
        allowed = new bool[](n);
        targets = new uint128[](n);
        usdPrices = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address q = r.quoteList(i);
            (bool a,,) = r.quotes(q);
            (assets[i], allowed[i]) = (q, a);
            if (!a) continue;
            try r.curveParams(q) returns (QuoteRegistry.CurveParams memory cp) {
                (targets[i], usdPrices[i]) = (cp.target, cp.quoteUsd);
            } catch {}
        }
    }

    function _spot(HookLaunchpad.Launch memory l) internal pure returns (uint256) {
        if (l.complete) return Math.mulDiv(uint256(l.virtualQuote) + l.target, 1e36, uint256(l.virtualTokens) - CURVE_SUPPLY);
        return Math.mulDiv(uint256(l.virtualQuote) + l.reserve, 1e36, uint256(l.virtualTokens) - l.tokensSold);
    }
}
