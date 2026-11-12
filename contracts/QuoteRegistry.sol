// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title QuoteRegistry
/// @notice The quote assets a token can be paired with (native AVAX, USDC, tokenized stocks), each
///         with a Chainlink USD feed, and the USD market caps every curve starts and graduates at.
///         At launch the launchpad asks for curve parameters: the USD targets are converted into the
///         chosen quote asset at the feed price of that moment and frozen into the launch.
///
///   Curve math: x·y = k on virtual reserves (x0 quote, y0 tokens), 800M tokens sold.
///   With r = endFdv / startFdv: y1 = 800M / (√r − 1) tokens remain virtual at the end, y0 = y1 + 800M,
///   x0 = startFdv · y0 / 1B, and the raise is x0·y0/y1 − x0. The pool then opens at the curve's last
///   price with raise / lastPrice tokens; r ≥ 16 keeps that at or under the 200M reserved for it.
contract QuoteRegistry is Ownable2Step {
    struct Quote {
        bool allowed;
        uint8 decimals;
        address feed; // Chainlink <ASSET>/USD
    }

    struct CurveParams {
        uint128 virtualQuote; // x0
        uint128 virtualTokens; // y0
        uint128 target; // quote raised when the curve sells out
        uint256 quoteUsd; // feed price used, 18 decimals
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant MAX_STALENESS = 26 hours; // Chainlink heartbeats on C-Chain are 24h

    /// @notice USD market caps (8 decimals) a curve starts at and graduates at.
    uint128 public startFdvUsd = 2_500e8;
    uint128 public endFdvUsd = 50_000e8;

    struct PriceBounds {
        uint128 min; // 18 decimals, 0 = no floor
        uint128 max; // 18 decimals, 0 = no ceiling
    }

    mapping(address => Quote) public quotes;
    address[] public quoteList;
    /// @notice Optional sanity range for each quote's USD price: a feed answer outside it is refused
    ///         like a stale one, so a broken or compromised feed can't set absurd curve parameters.
    mapping(address => PriceBounds) public priceBounds;
    mapping(address => bool) internal _listed;

    event QuoteSet(address indexed quote, bool allowed, address feed, uint8 decimals);
    event FdvSet(uint128 startFdvUsd, uint128 endFdvUsd);
    event PriceBoundsSet(address indexed quote, uint128 min, uint128 max);

    error BadArgs();
    error QuoteNotAllowed();
    error StalePrice();
    error PriceOutOfBounds();

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Allow (or retire) a quote asset. Native AVAX is address(0). Only plain ERC-20s:
    ///         no fee-on-transfer, no rebasing. Retiring takes any feed, including none (then
    ///         `usdPrice` stops answering for it too) and doesn't read it, so a dead feed can't block it.
    function setQuote(address quote, bool allowed, address feed) external onlyOwner {
        if (allowed && feed == address(0)) revert BadArgs();
        uint8 dec = quote == address(0) ? 18 : IERC20Metadata(quote).decimals();
        if (!_listed[quote]) {
            _listed[quote] = true;
            quoteList.push(quote);
        }
        quotes[quote] = Quote(allowed, dec, feed);
        if (allowed) _price(quote, feed); // must be readable now
        emit QuoteSet(quote, allowed, feed, dec);
    }

    /// @notice Sanity range for a quote's USD price (18 decimals; 0 disables that side).
    function setPriceBounds(address quote, uint128 min, uint128 max) external onlyOwner {
        if (max != 0 && max < min) revert BadArgs();
        priceBounds[quote] = PriceBounds(min, max);
        emit PriceBoundsSet(quote, min, max);
    }

    function setFdv(uint128 _startFdvUsd, uint128 _endFdvUsd) external onlyOwner {
        // r >= 16 keeps the graduation pool within the 200M tokens reserved for it.
        if (_startFdvUsd == 0 || _endFdvUsd < uint256(_startFdvUsd) * 16) revert BadArgs();
        startFdvUsd = _startFdvUsd;
        endFdvUsd = _endFdvUsd;
        emit FdvSet(_startFdvUsd, _endFdvUsd);
    }

    function quoteCount() external view returns (uint256) {
        return quoteList.length;
    }

    /// @notice USD price of one whole unit of `quote`, 18 decimals.
    function usdPrice(address quote) public view returns (uint256) {
        Quote memory q = quotes[quote];
        if (q.feed == address(0)) revert QuoteNotAllowed();
        return _price(quote, q.feed);
    }

    /// @notice Frozen curve parameters for a launch paired with `quote`, at today's price.
    function curveParams(address quote) external view returns (CurveParams memory p) {
        Quote memory q = quotes[quote];
        if (!q.allowed) revert QuoteNotAllowed();
        p.quoteUsd = _price(quote, q.feed);

        // √(end/start) scaled by 1e18
        uint256 sqrtR = Math.sqrt(Math.mulDiv(endFdvUsd, 1e36, startFdvUsd));
        uint256 y1 = Math.mulDiv(CURVE_SUPPLY, 1e18, sqrtR - 1e18);
        uint256 y0 = y1 + CURVE_SUPPLY;
        // start FDV in quote units: usd(8dp → 18dp) · 10^dec / price(18dp)
        uint256 startFdvQuote = Math.mulDiv(uint256(startFdvUsd) * 1e10, 10 ** q.decimals, p.quoteUsd);
        uint256 x0 = Math.mulDiv(startFdvQuote, y0, TOTAL_SUPPLY);
        uint256 x1 = Math.mulDiv(x0, y0, y1, Math.Rounding.Ceil);
        // A raise of under 1,000 base units would round fees and prices to nothing: refuse it.
        if (x0 == 0 || x1 - x0 < 1_000) revert BadArgs();

        p.virtualQuote = SafeCast.toUint128(x0);
        p.virtualTokens = SafeCast.toUint128(y0);
        p.target = SafeCast.toUint128(x1 - x0);
    }

    /// @dev Zero, negative, stale (or future-dated) answers and prices outside the quote's bounds revert.
    function _price(address quote, address feed) internal view returns (uint256 p) {
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(feed).latestRoundData();
        if (answer <= 0 || updatedAt > block.timestamp || updatedAt + MAX_STALENESS < block.timestamp) revert StalePrice();
        uint8 d = IChainlinkFeed(feed).decimals();
        if (d > 36) revert BadArgs();
        // normalise any feed to 18 decimals
        p = d <= 18 ? uint256(answer) * 10 ** (18 - d) : uint256(answer) / 10 ** (d - 18);
        PriceBounds memory b = priceBounds[quote];
        if (p == 0 || p < b.min || (b.max != 0 && p > b.max)) revert PriceOutOfBounds();
    }
}
