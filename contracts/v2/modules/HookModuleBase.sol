// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHookModule, ModuleCaps} from "../interfaces/IHookModule.sol";

interface IAvaxHookV2View {
    function poolManager() external view returns (IPoolManager);
    function launchpad() external view returns (address);
    function quoteRegistry() external view returns (address);
    function openedAt(PoolId id) external view returns (uint256);
}

interface IQuotePrices {
    function usdPrice(address quote) external view returns (uint256);
    function quotes(address quote) external view returns (bool allowed, uint8 decimals, address feed);
}

/// @title HookModuleBase
/// @notice Base for AvaxHook v2 modules: hook-only callbacks, no-op defaults for the callbacks a module
///         doesn't declare, and read helpers (pool open time, market cap in USD from the live QuoteRegistry).
///         Modules keep per-pool state keyed by PoolId; they never call the PoolManager to move value.
abstract contract HookModuleBase is IHookModule {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;

    address public immutable hook;
    IPoolManager public immutable poolManager;

    error OnlyHook();
    error BadConfig();
    error AlreadyRegistered();

    constructor(address _hook) {
        hook = _hook;
        poolManager = IAvaxHookV2View(_hook).poolManager();
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    function capabilities() external view virtual returns (uint16);

    function conflictGroups() external view virtual returns (uint32) {
        return 0;
    }

    function validateConfig(bytes calldata config) public view virtual;

    function onRegister(PoolId, address, address, address, bytes calldata) external virtual;

    function onBeforeSwap(SwapContext calldata) external virtual returns (uint24, Credit[] memory) {
        return (0, new Credit[](0));
    }

    function onAfterSwap(SwapContext calldata) external virtual returns (Credit[] memory) {
        return new Credit[](0);
    }

    function onTransfer(PoolId, address, address, address, address, uint256) external virtual {}

    function onLiquidity(PoolId, address, bool, ModifyLiquidityParams calldata) external virtual {}

    // ---------------------------------------------------------------- helpers

    function _one(address to, uint256 amount) internal pure returns (Credit[] memory c) {
        c = new Credit[](1);
        c[0] = Credit(to, amount);
    }

    /// @dev Block timestamp the pool opened at (0 while still on the curve).
    function _openedAt(PoolId id) internal view returns (uint256) {
        return IAvaxHookV2View(hook).openedAt(id);
    }

    /// @dev Market cap (1B supply) in quote base units at `sqrtPriceX96`.
    function _marketCapQuote(address token, address quote, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (quote < token) {
            // quote is currency0: price (token per quote) = P, quote per token = 1/P
            return Math.mulDiv(Math.mulDiv(TOTAL_SUPPLY, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        }
        return Math.mulDiv(Math.mulDiv(TOTAL_SUPPLY, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
    }

    /// @dev Market cap in USD (18 decimals), priced through the live QuoteRegistry's feed for the quote.
    function _marketCapUsd(address token, address quote, uint160 sqrtPriceX96) internal view returns (uint256) {
        IQuotePrices r = IQuotePrices(IAvaxHookV2View(hook).quoteRegistry());
        (, uint8 dec,) = r.quotes(quote);
        return Math.mulDiv(_marketCapQuote(token, quote, sqrtPriceX96), r.usdPrice(quote), 10 ** dec);
    }

    /// @dev Current pool price (for reads outside a swap callback, e.g. cross-pool rules).
    function _sqrtPrice(PoolId id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(id);
    }
}
