// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase, IAvaxHookV2View, IQuotePrices} from "./HookModuleBase.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title SlidingCapsModule
/// @notice Separate per-buy and per-sell caps that change with the token's USD market cap: a launch level
///         plus up to 5 market-cap levels. The level in force is the highest one the market cap is at now,
///         so the caps slide back if the market cap drops.
///   - Applies on the bonding curve (curve price) and in the pool alike.
///   - Market cap: the token's price before the transaction's first trade (1B supply), priced in USD
///     through the live QuoteRegistry. The level is fixed for the whole transaction, so a transaction
///     can't push the price up mid-way to unlock looser caps for itself. If the USD price is unavailable
///     (stale feed), the launch level applies.
///   - Caps are in tokens, per transaction: tokens received by all its buys, tokens sold by all its sells.
///     A cap of 0 means no cap on that side at that level.
///   - Every trade counts (router or not). Sell caps refuse sells, so
///     the module declares BLOCKS_SELLS.
contract SlidingCapsModule is HookModuleBase, TxTally {
    struct Level {
        uint64 mcUsd; // whole US dollars, strictly increasing
        uint16 buyBps; // max tokens per buy at this level, of the 1B supply (0 = no cap)
        uint16 sellBps; // max tokens per sell at this level, of the 1B supply (0 = no cap)
    }

    struct Config {
        uint16 buyBps; // launch level (below the first market cap)
        uint16 sellBps;
        Level[] levels; // up to 5
    }

    struct Rule {
        uint64[5] mcUsd;
        uint16[6] buyBps; // [0] = launch level
        uint16[6] sellBps;
        uint8 n; // number of market-cap levels
        bool registered;
        address token;
        address quote;
    }

    uint256 public constant MAX_LEVELS = 5;
    uint16 public constant MIN_CAP_BPS = 1;
    bytes32 internal constant LEVEL = keccak256("avaxhook.v2.sliding.level");
    bytes32 internal constant BOUGHT = keccak256("avaxhook.v2.sliding.bought");

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    error BuyCapExceeded(uint256 bought, uint256 cap);
    error SellCapExceeded(uint256 sold, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_BUY_CAP | ModuleCaps.GROUP_SELL_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        uint256 n = c.levels.length;
        if (n > MAX_LEVELS) revert BadConfig();
        bool any = c.buyBps != 0 || c.sellBps != 0;
        if (c.buyBps > BPS || c.sellBps > BPS) revert BadConfig();
        uint256 prev;
        for (uint256 i; i < n; ++i) {
            Level memory l = c.levels[i];
            if (l.mcUsd <= prev || l.buyBps > BPS || l.sellBps > BPS) revert BadConfig();
            prev = l.mcUsd;
            any = any || l.buyBps != 0 || l.sellBps != 0;
        }
        if (!any) revert BadConfig(); // caps nothing at all
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        r.buyBps[0] = c.buyBps;
        r.sellBps[0] = c.sellBps;
        for (uint256 i; i < c.levels.length; ++i) {
            r.mcUsd[i] = c.levels[i].mcUsd;
            r.buyBps[i + 1] = c.levels[i].buyBps;
            r.sellBps[i + 1] = c.levels[i].sellBps;
        }
        r.n = uint8(c.levels.length);
        r.registered = true;
        r.token = token;
        r.quote = quote;
        poolOf[token] = id;
    }

    /// @dev Fixes the transaction's level at its first swap (pre-swap price) and checks sells.
    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        Rule storage r = _rules[ctx.poolId];
        uint256 level = _txLevel(ctx, r);
        if (!ctx.isBuy) {
            uint16 bps = r.sellBps[level];
            if (bps != 0) {
                uint256 cap = (TOTAL_SUPPLY * bps) / BPS;
                // txVolume = tokens sold in this transaction on this pool, this swap included
                if (ctx.txVolume > cap) revert SellCapExceeded(ctx.txVolume, cap);
            }
        }
        return (0, new Credit[](0));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return new Credit[](0);
        Rule storage r = _rules[ctx.poolId];
        uint256 lvl = _tload(keccak256(abi.encode(LEVEL, ctx.poolId)));
        uint16 bps = r.buyBps[lvl == 0 ? 0 : lvl - 1];
        uint256 bought = _tallyAdd(keccak256(abi.encode(BOUGHT, ctx.poolId)), ctx.amountOut);
        if (bps != 0) {
            uint256 cap = (TOTAL_SUPPLY * bps) / BPS;
            if (bought > cap) revert BuyCapExceeded(bought, cap);
        }
        return new Credit[](0);
    }

    // ---------------------------------------------------------------- views

    /// @notice Caps at the pool price now (before graduation the pool has no price: launch level, mcUsd 0).
    /// @return level    0 = launch level, i = the i-th market-cap level
    /// @return mcUsd    market cap now in whole USD (0 if the price is unavailable)
    /// @return buyCap   max tokens per buy now (0 = no cap)
    /// @return sellCap  max tokens per sell now (0 = no cap)
    function currentCaps(address token) external view returns (uint256 level, uint256 mcUsd, uint256 buyCap, uint256 sellCap) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        (level, mcUsd) = _levelAt(r, _sqrtPrice(id));
        buyCap = (TOTAL_SUPPLY * r.buyBps[level]) / BPS;
        sellCap = (TOTAL_SUPPLY * r.sellBps[level]) / BPS;
    }

    /// @return mcUsd   level thresholds (whole USD)
    /// @return buyBps  [0] = launch level, then one per threshold
    /// @return sellBps same layout
    function levels(address token) external view returns (uint64[] memory mcUsd, uint16[] memory buyBps, uint16[] memory sellBps) {
        Rule storage r = _rules[poolOf[token]];
        uint256 n = r.n;
        mcUsd = new uint64[](n);
        buyBps = new uint16[](n + 1);
        sellBps = new uint16[](n + 1);
        for (uint256 i; i <= n; ++i) {
            if (i < n) mcUsd[i] = r.mcUsd[i];
            buyBps[i] = r.buyBps[i];
            sellBps[i] = r.sellBps[i];
        }
    }

    // ---------------------------------------------------------------- internals

    function _txLevel(SwapContext calldata ctx, Rule storage r) internal returns (uint256 level) {
        bytes32 key = keccak256(abi.encode(LEVEL, ctx.poolId));
        uint256 stored = _tload(key);
        if (stored != 0) return stored - 1;
        (level,) = _levelAt(r, ctx.sqrtPriceX96);
        _tstore(key, level + 1);
    }

    function _levelAt(Rule storage r, uint160 sqrtPriceX96) internal view returns (uint256 level, uint256 mcUsd) {
        uint256 n = r.n;
        if (n == 0 || sqrtPriceX96 == 0) return (0, 0); // (the pool has no price before graduation)
        bool ok;
        (ok, mcUsd) = _tryMarketCapUsd(r.token, r.quote, sqrtPriceX96);
        if (!ok) return (0, 0);
        for (uint256 i; i < n; ++i) {
            if (mcUsd < r.mcUsd[i]) break;
            level = i + 1;
        }
    }

    /// @dev Whole-dollar market cap; (false, 0) if the QuoteRegistry can't price the quote right now.
    function _tryMarketCapUsd(address token, address quote, uint160 sqrtPriceX96) internal view returns (bool, uint256) {
        IQuotePrices reg = IQuotePrices(IAvaxHookV2View(hook).quoteRegistry());
        uint8 dec;
        try reg.quotes(quote) returns (bool, uint8 d, address) {
            dec = d;
        } catch {
            return (false, 0);
        }
        try reg.usdPrice(quote) returns (uint256 p) {
            return (true, Math.mulDiv(_marketCapQuote(token, quote, sqrtPriceX96), p, 10 ** dec) / 1e18);
        } catch {
            return (false, 0);
        }
    }
}
