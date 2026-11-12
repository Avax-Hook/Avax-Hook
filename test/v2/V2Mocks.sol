// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HookModuleBase} from "../../contracts/v2/modules/HookModuleBase.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";

/// Configurable test module: optional revert, optional cut to itself, optional extra fee; can trigger moduleSwap.
contract ProbeModule is HookModuleBase {
    uint16 public caps;
    uint32 public groups;
    bool public revertAlways;
    uint256 public cutBps; // credited to this module from each side it sees
    uint24 public extraFee;
    uint256 public calls;
    address public lastTrader;
    uint256 public lastTxVolume;
    uint256 public lastTxSwaps;
    uint160 public lastPrice;
    bytes public lastExtra;

    constructor(address _hook, uint16 _caps, uint32 _groups) HookModuleBase(_hook) {
        caps = _caps;
        groups = _groups;
    }

    function set(bool _revert, uint256 _cutBps, uint24 _fee) external {
        (revertAlways, cutBps, extraFee) = (_revert, _cutBps, _fee);
    }

    function capabilities() external view override returns (uint16) {
        return caps;
    }

    function conflictGroups() external view override returns (uint32) {
        return groups;
    }

    function validateConfig(bytes calldata) public pure override {}

    function onRegister(PoolId, address, address, address, bytes calldata) external override onlyHook {}

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        _tick();
        (lastTrader, lastTxVolume, lastTxSwaps, lastPrice, lastExtra) = (ctx.trader, ctx.txVolume, ctx.txSwaps, ctx.sqrtPriceX96, ctx.extra);
        uint256 c = (ctx.amountIn * cutBps) / BPS;
        return (extraFee, c == 0 ? new Credit[](0) : _one(address(this), c));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        _tick();
        uint256 c = (ctx.amountOut * cutBps) / BPS;
        return c == 0 ? new Credit[](0) : _one(address(this), c);
    }

    function onTransfer(PoolId, address, address, address, address, uint256) external override onlyHook {
        _tick();
    }

    function onLiquidity(PoolId, address, bool, ModifyLiquidityParams calldata) external override onlyHook {
        _tick();
    }

    function _tick() internal {
        if (revertAlways) revert("probe says no");
        calls++;
    }

    function swapOwn(PoolKey calldata key, bool buy, uint256 amountIn, bool burnOut) external returns (uint256, uint256) {
        return AvaxHookV2(payable(hook)).moduleSwap(
            key, buy, amountIn, buy == (Currency.unwrap(key.currency0) == address(0)) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, burnOut
        );
    }
}

/// Swaps on the PoolManager directly (no router hookData), like an aggregator or searcher.
contract DirectSwapper is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    /// Pulls `amount` of `token` from `from` (needs approval), like an aggregator, then sells it.
    function sellFrom(PoolKey calldata key, address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
        bool zeroForOne = Currency.unwrap(key.currency0) == token;
        pm.unlock(abi.encode(key, zeroForOne, -int256(amount), uint160(0)));
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amt) external payable {
        pm.unlock(abi.encode(key, zeroForOne, amt, uint160(0)));
    }

    function swapWithLimit(PoolKey calldata key, bool zeroForOne, int256 amt, uint160 limit) external payable {
        pm.unlock(abi.encode(key, zeroForOne, amt, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amt, uint160 limit) = abi.decode(data, (PoolKey, bool, int256, uint160));
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        pm.swap(key, SwapParams(zeroForOne, amt, limit), "");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 owe = uint256(-d);
            if (c.isAddressZero()) {
                pm.settle{value: owe}();
            } else {
                pm.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(pm), owe);
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}
