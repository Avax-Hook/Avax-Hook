// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2} from "../../AvaxHookV2.sol";

/// @title PoolModules
/// @notice Whether an address is one of a pool's own modules (Auto-LP vaults, pots, ...). Transfer rules treat
///         those like the hook: their token moves (claims out of the PoolManager, liquidity adds, payouts) are
///         protocol plumbing, not a wallet buying, selling or holding. Only contracts are looked up, so the
///         wide `poolInfo` read is skipped for every EOA.
library PoolModules {
    function isModule(address hook, PoolId id, address a) internal view returns (bool) {
        if (a.code.length == 0) return false;
        address[] memory mods = AvaxHookV2(payable(hook)).poolInfo(id).modules;
        for (uint256 i; i < mods.length; ++i) {
            if (mods[i] == a) return true;
        }
        return false;
    }
}
