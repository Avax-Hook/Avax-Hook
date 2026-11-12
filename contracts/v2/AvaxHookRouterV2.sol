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

import {HookLaunchpadV2} from "./HookLaunchpadV2.sol";

/// @title AvaxHookRouterV2
/// @notice Exact-input quote <-> token swaps on graduated v2 pools. The only caller whose hookData the v2
///         hook trusts: it passes `abi.encode(trader, referrer, extra)` where trader is always msg.sender,
///         so modules (King of the Hill, pots, vesting, allowlists...) know who is buying or selling.
///         `extra` is opaque per-trade data for modules (e.g. an allowlist proof). Holds no funds.
contract AvaxHookRouterV2 is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    HookLaunchpadV2 public immutable launchpad;

    error Expired();
    error Slippage();
    error BadValue();
    error OnlyPoolManager();
    error TransferFailed();

    struct Call {
        address payer;
        address token;
        address referrer;
        bool isBuy;
        uint256 amountIn;
        uint256 minOut;
        bytes extra;
    }

    constructor(IPoolManager _poolManager, HookLaunchpadV2 _launchpad) {
        poolManager = _poolManager;
        launchpad = _launchpad;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    /// @notice Buy with the pool's quote asset. AVAX pools: send `amountIn` as value; ERC-20 quotes:
    ///         approve this router for `amountIn` first and send no value.
    function buy(address token, uint256 amountIn, uint256 minTokensOut, address referrer, uint256 deadline, bytes calldata extra)
        external
        payable
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        bool native = launchpad.quoteOf(token) == address(0);
        if (native ? msg.value != amountIn : msg.value != 0) revert BadValue();
        out = abi.decode(
            poolManager.unlock(abi.encode(Call(msg.sender, token, referrer, true, amountIn, minTokensOut, extra))), (uint256)
        );
    }

    /// @notice Sell tokens for the pool's quote asset (approve this router for the token first).
    function sell(address token, uint256 amountIn, uint256 minQuoteOut, uint256 deadline, bytes calldata extra)
        external
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert Expired();
        out = abi.decode(
            poolManager.unlock(abi.encode(Call(msg.sender, token, address(0), false, amountIn, minQuoteOut, extra))), (uint256)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        Call memory c = abi.decode(data, (Call));
        PoolKey memory key = launchpad.poolKey(c.token);
        bool tokenIs1 = Currency.unwrap(key.currency1) == c.token;
        (Currency quoteC, Currency tokenC) = tokenIs1 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bool zeroForOne = c.isBuy == tokenIs1;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(c.amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(c.payer, c.referrer, c.extra)
        );
        (int128 inDelta, int128 outDelta) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 paid = uint256(uint128(-inDelta));
        uint256 out = uint256(uint128(outDelta));
        if (out < c.minOut) revert Slippage();

        Currency inC = c.isBuy ? quoteC : tokenC;
        Currency outC = c.isBuy ? tokenC : quoteC;
        if (inC.isAddressZero()) {
            poolManager.settle{value: paid}();
            if (c.amountIn > paid) _sendNative(c.payer, c.amountIn - paid);
        } else {
            poolManager.sync(inC);
            IERC20(Currency.unwrap(inC)).safeTransferFrom(c.payer, address(poolManager), paid);
            poolManager.settle();
        }
        poolManager.take(outC, c.payer, out);
        return abi.encode(out);
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
