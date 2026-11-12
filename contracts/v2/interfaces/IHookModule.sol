// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title IHookModule
/// @notice A rule that AvaxHookV2 runs for the pools that picked it at launch. A module is a singleton
///         shared by every pool that uses it: it keeps per-pool state keyed by PoolId, and only the
///         hook may call its callbacks (see HookModuleBase).
///
///   Capabilities (`capabilities()`, read once when the Safe approves the module and frozen into each
///   pool at launch) say which callbacks the hook makes. A module never touches the PoolManager: it asks
///   the hook for value moves by returning `Credit`s, and the hook does the v4 delta accounting.
///
///   Swap callbacks run for pool swaps AND for bonding-curve trades (SwapContext.phase), with the same
///   dispatch, caps, isolation and credit semantics.
///
///   Credits: `onBeforeSwap` credits come out of the swap INPUT (quote on buys, token on sells),
///   `onAfterSwap` credits come out of the swap OUTPUT (token on buys, quote on sells). Recipients:
///     - any account     -> claimable balance in the hook (pull, `AvaxHookV2.claim`; token claims earned on
///                          the curve are withdrawable once the token graduates)
///     - BURN (0x…dEaD)  -> sent straight to 0x…dEaD
///     - LP_DONATE       -> donated to in-range liquidity of the pool (curve: see ModuleCaps.LP_DONATE)
///   The sum of every module's credits in one callback is capped at MAX_MODULE_CUT_BPS of that side: the hook
///   runs every module first, then books, scaling every credit down by the same factor when they ask for more
///   (never a revert). At most AvaxHookV2.MAX_CREDITS credits per callback are read; credits to address(0)
///   are skipped; malformed return data reads as no fee and no credits.
///
///   Failure model: a revert in a module reverts the trade (or transfer) — that is how a rule says no.
///   EXCEPT on the sell path of a module without BLOCKS_SELLS: there the hook calls it with a fixed
///   gas budget and ignores a revert, so a buggy module can never stop holders from selling.
interface IHookModule {
    struct Credit {
        address to;
        uint256 amount;
    }

    /// @dev Everything the hook knows about a trade. Two phases (`phase`):
    ///      PHASE_POOL  a Uniswap v4 swap after graduation. `trader`, `referrer` and `extra` are only set when
    ///                  the swap came through the trusted AvaxHook router (its hookData names the payer); anyone
    ///                  else could name anybody, so for them all three are empty.
    ///      PHASE_CURVE a bonding-curve trade on HookLaunchpadV2 (buy, sell, dev buy at launch, trusted-caller
    ///                  buys/sells). `trader` is always set: the launchpad's msg.sender, or the recipient `to` of a
    ///                  trusted caller's buyWithQuoteFor; `sender` is the launchpad's msg.sender; `referrer`/`extra`
    ///                  come from buyWithData/sellWithData. Amounts and `sqrtPriceX96` (the curve's spot price in
    ///                  pool orientation, so market-cap helpers work unchanged) follow pool semantics. The pool
    ///                  does not exist yet: rules that only make sense on the pool (LP donations, buybacks,
    ///                  LP-fee overrides, reading pool liquidity) should check `phase`.
    struct SwapContext {
        PoolId poolId;
        address token; // the launched token
        address quote; // quote asset, address(0) = native AVAX
        address creator;
        address sender; // PoolManager caller (router, aggregator, bot)
        address trader; // trusted buyer/seller identity, or address(0)
        address referrer; // trusted referrer from the router, or address(0)
        bool isBuy; // quote in, token out
        uint256 amountIn; // exact input (quote on buys, tokens on sells), before any cut
        uint256 amountOut; // swap output before after-swap cuts (0 in onBeforeSwap)
        uint256 txVolume; // this transaction's running input volume on this pool and side, incl. this swap
        uint256 txSwaps; // swaps on this pool in this transaction so far, incl. this one (both sides)
        uint160 sqrtPriceX96; // pool price before the swap (onBeforeSwap) / after it (onAfterSwap)
        bytes extra; // opaque per-trade data from the trusted router (e.g. a Merkle proof), else empty
        uint8 phase; // ModuleCaps.PHASE_POOL (0) or ModuleCaps.PHASE_CURVE (1)
    }

    function hook() external view returns (address);

    /// @notice Bitmask of ModuleCaps flags.
    function capabilities() external view returns (uint16);

    /// @notice Bitmask of conflict groups (ModuleCaps.GROUP_*). Two modules sharing a bit can't be launched
    ///         together (e.g. two holding caps).
    function conflictGroups() external view returns (uint32);

    /// @notice Reverts unless `config` is a valid encoding for this module. Context-dependent checks
    ///         (partner token, quote decimals, creator) belong in `onRegister`, which may also revert.
    function validateConfig(bytes calldata config) external view;

    /// @notice Called once when a pool that uses this module is launched (before the curve opens).
    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external;

    /// @return extraFeePips added to the pool's LP fee for this swap (capped by the hook)
    /// @return credits      taken from the swap input
    ///         Curve phase: extraFeePips is an extra cut of the gross quote (buy input / sell output) added to
    ///         the graduation liquidity (the curve's stand-in for the LP fee).
    function onBeforeSwap(SwapContext calldata ctx) external returns (uint24 extraFeePips, Credit[] memory credits);

    /// @return credits taken from the swap output
    function onAfterSwap(SwapContext calldata ctx) external returns (Credit[] memory credits);

    /// @notice Every token move from launch on (curve phase included; see AvaxHookV2.isOpen), except
    ///         mints, burns and the launchpad seeding the pool at graduation. Called after balances are
    ///         updated, so `balanceOf(to)` already includes `amount`. `operator` is the account that
    ///         called the token (holder, spender, router, PoolManager, launchpad).
    function onTransfer(PoolId id, address token, address operator, address from, address to, uint256 amount) external;

    /// @notice Someone other than the launchpad adds (`isAdd`) or removes liquidity.
    function onLiquidity(PoolId id, address sender, bool isAdd, ModifyLiquidityParams calldata params) external;
}

/// @notice Capability flags and conflict groups a module declares.
library ModuleCaps {
    uint16 internal constant BEFORE_SWAP = 1 << 0;
    uint16 internal constant AFTER_SWAP = 1 << 1;
    uint16 internal constant ON_TRANSFER = 1 << 2;
    uint16 internal constant LIQUIDITY = 1 << 3;
    /// @dev The module's rule may refuse sells (vesting, hot potato, market hours). Without it, the hook
    ///      isolates the module on the sell path: a revert there is ignored instead of reverting the sell.
    uint16 internal constant BLOCKS_SELLS = 1 << 4;
    uint16 internal constant ALL = (1 << 5) - 1;

    // Conflict groups: two modules that share one can't be combined in a launch.
    uint32 internal constant GROUP_HOLDING_CAP = 1 << 0; // max per wallet, chapters, rising cap
    uint32 internal constant GROUP_BUY_CAP = 1 << 1; // per-buy size caps (whale guard, sliding caps, oscillators)
    uint32 internal constant GROUP_SELL_CAP = 1 << 2; // per-sell size caps
    uint32 internal constant GROUP_RECEIVER_LIST = 1 << 3; // blocklist / allowlist / holder-gated
    uint32 internal constant GROUP_VENUE = 1 << 4; // venue-locked / DEX-only / P2P-only
    uint32 internal constant GROUP_SCHEDULE = 1 << 5; // market hours / trading hours
    uint32 internal constant GROUP_SELL_LOCK = 1 << 6; // vesting / hot potato / entangled
    uint32 internal constant GROUP_CROWN = 1 << 7; // king of the hill
    uint32 internal constant GROUP_TURN = 1 << 8; // ping pong
    // bits 9..31 reserved for future groups

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    /// @dev Pool phase: donated to in-range LPs. Curve phase: quote goes to the graduation liquidity,
    ///      tokens are burned.
    address internal constant LP_DONATE = address(1);

    // SwapContext.phase
    uint8 internal constant PHASE_POOL = 0;
    uint8 internal constant PHASE_CURVE = 1;
}
