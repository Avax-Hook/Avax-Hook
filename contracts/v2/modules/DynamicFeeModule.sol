// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title DynamicFeeModule
/// @notice v1 "Dynamic fee" (surge): the LP fee rises from the pool's base fee toward `maxFeePips` as a trade
///         gets larger relative to the in-range depth on its input side. Sized on the pool's cumulative
///         volume on that side in the current BLOCK (this swap included, kept in storage), so splitting a
///         trade into several swaps or several transactions of one block doesn't dodge the surge.
///         extra = (maxFeePips - baseFee) * min(1, blockVolume * surgeSens / reserveIn).
///         Limits: the volume is per block, not per trader: everyone trading one side in a block shares the
///         surge (a later buyer in a busy block pays more), and a trade spread over consecutive blocks is
///         sized block by block. One storage write per pool-phase swap.
///         Applies to buys and sells; never refuses anything.
///         Pool phase only (it reads pool liquidity and overrides the LP fee): a no-op on the bonding curve.
contract DynamicFeeModule is HookModuleBase {
    using StateLibrary for IPoolManager;

    struct Config {
        uint24 maxFeePips; // ceiling for base + surge, <= 100,000 (10%), above the pool's base fee
        uint8 surgeSens; // 1 .. 10
    }

    struct Surge {
        uint24 range; // maxFeePips - base fee
        uint8 sens;
    }

    uint24 public constant MAX_SURGE_FEE_PIPS = 100_000;
    uint256 internal constant PIPS = 1_000_000;

    /// @dev This block's input volume per side (one slot; volumes saturate at uint96 max).
    struct BlockVolume {
        uint64 block_;
        uint96 zeroForOne;
        uint96 oneForZero;
    }

    mapping(PoolId => Surge) internal _surge;
    mapping(PoolId => BlockVolume) internal _volume;

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.maxFeePips == 0 || c.maxFeePips > MAX_SURGE_FEE_PIPS || c.surgeSens == 0 || c.surgeSens > 10) revert BadConfig();
    }

    /// @dev The ceiling must sit above the pool's base fee (core config, already stored when modules register).
    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        if (_surge[id].sens != 0) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        uint24 base = AvaxHookV2(payable(hook)).poolInfo(id).baseFeePips;
        if (c.maxFeePips <= base) revert BadConfig();
        _surge[id] = Surge(c.maxFeePips - base, c.surgeSens);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.phase == ModuleCaps.PHASE_CURVE) return (0, new Credit[](0));
        Surge memory s = _surge[ctx.poolId];
        if (s.sens == 0) return (0, new Credit[](0));
        bool zeroForOne = ctx.isBuy == (ctx.quote < ctx.token);
        uint256 vol = _addVolume(ctx.poolId, zeroForOne, ctx.amountIn);
        // ctx.txVolume <= vol unless a swap of this tx predates this module's bookkeeping; take the larger
        if (ctx.txVolume > vol) vol = ctx.txVolume;
        return (uint24(_extra(ctx.poolId, s, ctx.sqrtPriceX96, zeroForOne, vol)), new Credit[](0));
    }

    /// @notice The surge add-on (pips) a trade of `amountIn` on side `isBuy` would pay now (on top of the
    ///         volume already traded on that side in this block).
    function quoteSurge(PoolId id, address token, address quote, bool isBuy, uint256 amountIn) external view returns (uint256) {
        bool zeroForOne = isBuy == (quote < token);
        return _extra(id, _surge[id], _sqrtPrice(id), zeroForOne, blockVolume(id, zeroForOne) + amountIn);
    }

    /// @notice Input volume on side `zeroForOne` already traded in the current block.
    function blockVolume(PoolId id, bool zeroForOne) public view returns (uint256) {
        BlockVolume memory v = _volume[id];
        if (v.block_ != block.number) return 0;
        return zeroForOne ? v.zeroForOne : v.oneForZero;
    }

    /// @dev Adds `amountIn` to this block's volume on the side and returns the new total (this swap included).
    function _addVolume(PoolId id, bool zeroForOne, uint256 amountIn) internal returns (uint256 total) {
        BlockVolume memory v = _volume[id];
        if (v.block_ != block.number) v = BlockVolume(uint64(block.number), 0, 0);
        total = (zeroForOne ? v.zeroForOne : v.oneForZero) + amountIn;
        uint96 stored = total > type(uint96).max ? type(uint96).max : uint96(total);
        if (zeroForOne) v.zeroForOne = stored;
        else v.oneForZero = stored;
        _volume[id] = v;
    }

    function _extra(PoolId id, Surge memory s, uint160 sqrtPriceX96, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (s.sens == 0 || amountIn == 0 || sqrtPriceX96 == 0) return 0;
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0) return 0;
        uint256 reserveIn =
            zeroForOne ? (uint256(liquidity) << 96) / sqrtPriceX96 : (uint256(liquidity) * sqrtPriceX96) >> 96;
        if (reserveIn == 0) return 0;
        uint256 ratio = (amountIn * s.sens * PIPS) / reserveIn;
        if (ratio > PIPS) ratio = PIPS;
        return (uint256(s.range) * ratio) / PIPS;
    }
}
