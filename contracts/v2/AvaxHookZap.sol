// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AvaxHookV2} from "./AvaxHookV2.sol";
import {AvaxHookRouterV2} from "./AvaxHookRouterV2.sol";
import {HookLaunchpadV2} from "./HookLaunchpadV2.sol";

/// @title AvaxHookZap
/// @notice One-transaction buys and sells of graduated tokens with any asset: ParaSwap (Augustus v6.2) between
///         the asset and the pool's quote, then AvaxHookRouterV2 for the pool, in a single call. Holds nothing
///         between calls: every leftover (unspent input, router refunds, aggregator surplus) goes back to the
///         caller in the same transaction.
///   Trader identity: the router names its caller (this contract) as the trader, so modules that pay or
///   restrict a specific wallet (crowns, pots, referrals, buyer rewards, hot potato, holding caps) would treat
///   the zap as the buyer. `buy` / `sell` therefore refuse any pool with a module not marked identity-neutral
///   by the owner; the app sends those pools through two transactions from the wallet instead.
///   Fee-on-transfer sources arrive short, so Augustus can't pull the full amount and the call reverts (no loss).
///   Aggregator calldata: only Augustus is ever called, ERC-20s are approved to it (v6.2 pulls them itself,
///   there is no separate TokenTransferProxy) for exactly the amount and reset to zero after, and the output
///   is measured by balance deltas, so a bad route can only cost its own caller (bounded by the caller's own
///   minimums).
///   History: the first zaps (v2 0x9C60…990d, v3 0xd6e6…ad3eb) were pinned to Augustus v5
///   (0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57, spender 0x216B4B4Ba9F3e719726886d34a177484278Bfcae);
///   ParaSwap's API stopped quoting v5 in November 2026, so this version is pinned to v6.2.
contract AvaxHookZap is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public constant AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068;
    /// @notice Where ERC-20 approvals go: Augustus v6.2 itself.
    address public constant SPENDER = AUGUSTUS;
    address internal constant NATIVE = address(0);

    AvaxHookRouterV2 public immutable router;
    HookLaunchpadV2 public immutable launchpad;
    AvaxHookV2 public immutable hook;

    /// @notice Modules that never look at who trades (no trader-keyed rewards, limits or transfer rules).
    mapping(address => bool) public neutral;

    struct Buy {
        address token; // graduated launch to buy
        address src; // asset paid, address(0) = AVAX; never the pool's quote (use the router directly)
        uint256 srcAmount;
        bytes swapData; // Augustus calldata: src -> quote, srcAmount, receiver this contract
        uint256 minQuote; // least quote the aggregator leg must deliver
        uint256 minTokensOut;
        uint256 deadline;
    }

    struct Sell {
        address token;
        uint256 amount; // tokens sold
        uint256 minQuote; // least quote the pool leg must pay
        address dest; // asset received, address(0) = AVAX; never the pool's quote
        uint256 aggIn; // quote the aggregator leg spends (what `swapData` was built for), <= the pool's output
        bytes swapData; // Augustus calldata: quote -> dest, aggIn, receiver this contract
        uint256 minDestOut;
        uint256 deadline;
    }

    event Zapped(address indexed user, address indexed token, bool isBuy, address asset, uint256 amountIn, uint256 amountOut);
    event NeutralSet(address indexed module, bool neutral);

    error Expired();
    error NotGraduated();
    error IdentityModule(address module);
    error SameAsQuote();
    error BadValue();
    error AggregatorFailed();
    error Slippage();
    error TransferFailed();

    constructor(AvaxHookRouterV2 _router, address[] memory neutralModules, address owner_) Ownable(owner_) {
        router = _router;
        launchpad = _router.launchpad();
        hook = AvaxHookV2(payable(address(launchpad.hook())));
        for (uint256 i; i < neutralModules.length; ++i) {
            neutral[neutralModules[i]] = true;
            emit NeutralSet(neutralModules[i], true);
        }
    }

    receive() external payable {}

    function setNeutral(address module, bool isNeutral) external onlyOwner {
        neutral[module] = isNeutral;
        emit NeutralSet(module, isNeutral);
    }

    /// @notice Whether `token` can go through the zap: graduated, and every module identity-neutral. The app
    ///         reads this first and sends tokens that can't through two wallet transactions instead, so callers
    ///         never meet the revert in `buy` / `sell`, which only guards direct calls.
    /// @return ok true if zappable; blocker the first module that isn't neutral (address(0) if none, or if
    ///         the token hasn't graduated)
    function zappable(address token) public view returns (bool ok, address blocker) {
        HookLaunchpadV2.Launch memory l = launchpad.getLaunch(token);
        if (!l.graduated) return (false, address(0));
        address[] memory mods = hook.poolInfo(hook.poolOfToken(token)).modules;
        for (uint256 i; i < mods.length; ++i) {
            if (!neutral[mods[i]]) return (false, mods[i]);
        }
        return (true, address(0));
    }

    /// @notice Pays `srcAmount` of `src` (AVAX as value), routes it to the pool's quote and buys the token.
    function buy(Buy calldata a) external payable nonReentrant returns (uint256 tokensOut) {
        if (block.timestamp > a.deadline) revert Expired();
        address quote = _checkPool(a.token);
        if (a.src == quote) revert SameAsQuote();
        if (a.src == NATIVE ? msg.value != a.srcAmount : msg.value != 0) revert BadValue();
        if (a.src != NATIVE) IERC20(a.src).safeTransferFrom(msg.sender, address(this), a.srcAmount);

        // Aggregator leg: src -> quote, measured by what arrived.
        uint256 q0 = _balance(quote);
        _aggregate(a.src, a.srcAmount, a.swapData);
        uint256 got = _balance(quote) - q0;
        if (got < a.minQuote) revert Slippage();

        // Pool leg: the router pulls the quote (ERC-20) or takes it as value, and refunds what it didn't use.
        uint256 t0 = IERC20(a.token).balanceOf(address(this));
        if (quote == NATIVE) {
            router.buy{value: got}(a.token, got, a.minTokensOut, address(0), a.deadline, "");
        } else {
            IERC20(quote).forceApprove(address(router), got);
            router.buy(a.token, got, a.minTokensOut, address(0), a.deadline, "");
            IERC20(quote).forceApprove(address(router), 0);
        }
        tokensOut = IERC20(a.token).balanceOf(address(this)) - t0;
        if (tokensOut < a.minTokensOut) revert Slippage();
        IERC20(a.token).safeTransfer(msg.sender, tokensOut);

        _sweep(a.src);
        _sweep(quote);
        emit Zapped(msg.sender, a.token, true, a.src, a.srcAmount, tokensOut);
    }

    /// @notice Sells `amount` tokens for the pool's quote, then routes `aggIn` of it to `dest`; any quote
    ///         beyond `aggIn` is returned as is.
    function sell(Sell calldata a) external nonReentrant returns (uint256 destOut) {
        if (block.timestamp > a.deadline) revert Expired();
        address quote = _checkPool(a.token);
        if (a.dest == quote) revert SameAsQuote();
        IERC20(a.token).safeTransferFrom(msg.sender, address(this), a.amount);

        // Pool leg.
        uint256 q0 = _balance(quote);
        IERC20(a.token).forceApprove(address(router), a.amount);
        router.sell(a.token, a.amount, a.minQuote, a.deadline, "");
        IERC20(a.token).forceApprove(address(router), 0);
        uint256 got = _balance(quote) - q0;
        if (got < a.minQuote || got < a.aggIn) revert Slippage();

        // Aggregator leg: quote -> dest.
        uint256 d0 = _balance(a.dest);
        _aggregate(quote, a.aggIn, a.swapData);
        destOut = _balance(a.dest) - d0;
        if (destOut < a.minDestOut) revert Slippage();
        _send(a.dest, msg.sender, destOut);

        _sweep(quote);
        _sweep(a.token);
        emit Zapped(msg.sender, a.token, false, a.dest, a.amount, destOut);
    }

    // ---------------------------------------------------------------- internals

    /// @dev The pool must be open, and every module identity-neutral. Returns its quote asset.
    function _checkPool(address token) internal view returns (address quote) {
        (bool ok, address blocker) = zappable(token);
        if (!ok) {
            if (blocker == address(0)) revert NotGraduated();
            revert IdentityModule(blocker);
        }
        return launchpad.quoteOf(token);
    }

    /// @dev Calls Augustus with `data`, spending `amount` of `asset` (value for AVAX, an exact, reset approval
    ///      to Augustus for ERC-20s).
    function _aggregate(address asset, uint256 amount, bytes calldata data) internal {
        bool ok;
        if (asset == NATIVE) {
            (ok,) = AUGUSTUS.call{value: amount}(data);
        } else {
            IERC20(asset).forceApprove(SPENDER, amount);
            (ok,) = AUGUSTUS.call(data);
            IERC20(asset).forceApprove(SPENDER, 0);
        }
        if (!ok) revert AggregatorFailed();
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == NATIVE ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /// @dev Returns whatever of `asset` this contract still holds to the caller (it never keeps funds).
    function _sweep(address asset) internal {
        uint256 b = _balance(asset);
        if (b > 0) _send(asset, msg.sender, b);
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }
}
