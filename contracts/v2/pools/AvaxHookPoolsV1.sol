// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {AvaxHookV2, IModuleSource} from "../AvaxHookV2.sol";

/// @title AvaxHookPoolsV1
/// @notice The existing-token (pools) profile's hook: AvaxHookV2 plus a true full-fill check (audit M-1).
///
///   AvaxHookV2 enforces "every swap fills completely" through the extreme price limit alone. That holds in
///   the launch profile (the graduated LP is locked) but not here: pool liquidity is ordinary, removable
///   PositionManager NFTs. In an empty or thin pool a swap runs to MIN/MAX price, uses little or none of its
///   input, and modules still saw (and cut, counted, qualified pots on) the full requested `amountIn`.
///
///   So this hook remembers, per pool, how much input the PoolManager must take once the before-swap cut is
///   off (`amountIn - cut`, transient) and afterSwap reverts PartialFillNotAllowed unless the pool's input
///   delta is exactly that. A swap in a pool without liquidity therefore reverts, so it can't move the price
///   for free either (the 1-wei price push).
contract AvaxHookPoolsV1 is AvaxHookV2 {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    /// @dev Transient: base slot of pool id => 1 + the input the pool itself must consume.
    bytes32 internal constant _EXPECTED_IN = keccak256("avaxhook.pools.expectedIn");

    constructor(IPoolManager _poolManager, address _deployer, IModuleSource _moduleRegistry, address _quoteRegistry)
        AvaxHookV2(_poolManager, _deployer, _moduleRegistry, _quoteRegistry)
    {}

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        public
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee)
    {
        (selector, delta, fee) = super.beforeSwap(sender, key, params, hookData);
        // Exact input only (checked above): amountSpecified < 0, the cut is the positive specified delta.
        uint256 expected = uint256(-params.amountSpecified) - uint256(int256(delta.getSpecifiedDelta()));
        bytes32 slot = _slot(key.toId());
        assembly ("memory-safe") {
            tstore(slot, add(expected, 1))
        }
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        public
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        bytes32 slot = _slot(key.toId());
        uint256 expected;
        assembly ("memory-safe") {
            expected := tload(slot)
            tstore(slot, 0)
        }
        int128 inDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (expected == 0 || inDelta >= 0 || uint256(uint128(-inDelta)) != expected - 1) revert PartialFillNotAllowed();
        return super.afterSwap(sender, key, params, delta, hookData);
    }

    function _slot(PoolId id) internal pure returns (bytes32 s) {
        s = keccak256(abi.encode(_EXPECTED_IN, id));
    }
}
