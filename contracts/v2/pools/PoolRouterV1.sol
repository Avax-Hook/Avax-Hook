// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title PoolRouterV1
/// @notice Exact-input swaps on the existing-token profile's pools (any pool of its hook, by PoolKey). The
///         only caller whose hookData that hook trusts: it passes `abi.encode(trader, referrer, extra)` with
///         trader = msg.sender, so modules know who trades. Holds no funds.
///
///         `quote` runs the same swap for a named trader and always reverts inside the PoolManager lock, so
///         it returns exact amounts after every cut (or the refusing module's reason) and moves nothing.
contract PoolRouterV1 is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable hook;

    struct Call {
        address payer; // the trader (quotes: the trader being quoted)
        address referrer;
        bool zeroForOne;
        bool isQuote;
        bytes32 tag; // quotes: a per-call value only this router knows (QuoteResult must echo it)
        uint256 amountIn;
        uint256 minOut;
        bytes extra;
    }

    error Expired();
    error Slippage();
    error BadValue();
    error BadPool();
    error OnlyPoolManager();
    /// @notice The pool took less than `amountIn` (not enough liquidity): refused, never a partial fill.
    error PartialFill(uint256 paid, uint256 amountIn);
    error QuoteResult(bytes32 tag, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager _poolManager, address _hook) {
        poolManager = _poolManager;
        hook = _hook;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    /// @notice Swaps exactly `amountIn` of the input currency. Native AVAX input: send it as value;
    ///         ERC-20 input: approve this router first and send no value.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        address referrer,
        uint256 deadline,
        bytes calldata extra
    ) external payable returns (uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        if (address(key.hooks) != hook) revert BadPool();
        if (amountIn == 0) revert BadValue();
        bool nativeIn = zeroForOne && key.currency0.isAddressZero();
        if (nativeIn ? msg.value != amountIn : msg.value != 0) revert BadValue();
        out = abi.decode(
            poolManager.unlock(abi.encode(key, Call(msg.sender, referrer, zeroForOne, false, bytes32(0), amountIn, minOut, extra))),
            (uint256)
        );
    }

    /// @notice Exact quote for `trader` (call with eth_call). `wouldRevert` with `reason` when the swap
    ///         would fail (a module refusing, a cap, no liquidity).
    function quote(PoolKey calldata key, bool zeroForOne, uint256 amountIn, address trader, address referrer, bytes calldata extra)
        external
        returns (uint256 amountOut, uint256 used, bool wouldRevert, bytes memory reason)
    {
        if (address(key.hooks) != hook) revert BadPool();
        // Audit I-2: only a QuoteResult carrying this call's tag is a result. The tag travels to our own
        // unlockCallback only (the PoolManager never hands the unlock data to hooks or modules) and mixes in
        // gasleft(), so nothing else in the swap path can forge one.
        bytes32 tag = keccak256(abi.encode(gasleft(), msg.sender, trader, amountIn, block.number));
        try poolManager.unlock(abi.encode(key, Call(trader, referrer, zeroForOne, true, tag, amountIn, 0, extra))) {
            // unreachable: a quote always reverts
        } catch (bytes memory err) {
            bytes32 got;
            if (err.length == 100 && bytes4(err) == QuoteResult.selector) {
                assembly ("memory-safe") {
                    got := mload(add(err, 36))
                    used := mload(add(err, 68))
                    amountOut := mload(add(err, 100))
                }
            }
            if (got != tag) {
                (used, amountOut) = (0, 0);
                (wouldRevert, reason) = (true, err);
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (PoolKey memory key, Call memory c) = abi.decode(data, (PoolKey, Call));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn),
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(c.payer, c.referrer, c.extra)
        );
        (int128 inDelta, int128 outDelta) = c.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 paid = uint256(uint128(-inDelta));
        uint256 out = uint256(uint128(outDelta));
        // Audit M-1: a swap counts (fees, modules, pots) only if it used its whole input. The pools hook
        // refuses partial fills too; this keeps the router honest on its own.
        if (paid != c.amountIn) revert PartialFill(paid, c.amountIn);
        // Nothing of a quote is ever settled: the revert unwinds the whole lock.
        if (c.isQuote) revert QuoteResult(c.tag, paid, out);
        if (out < c.minOut) revert Slippage();

        (Currency inC, Currency outC) = c.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (inC.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(inC);
            IERC20(Currency.unwrap(inC)).safeTransferFrom(c.payer, address(poolManager), paid);
            poolManager.settle();
        }
        poolManager.take(outC, c.payer, out);
        return abi.encode(out);
    }
}
