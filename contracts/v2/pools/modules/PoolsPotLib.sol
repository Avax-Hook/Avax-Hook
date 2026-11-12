// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2, IProtocolRecipientV2} from "../../AvaxHookV2.sol";

/// @notice Shared rules of the pools profile's pot modules (audit L-1, L-3).
library PoolsPotLib {
    /// @notice Pot share cap in the pools profile (2% of each buy; the launch profile allows 10%).
    uint16 internal constant MAX_POT_BPS = 200;

    /// @dev Orphaned pots go to the protocol recipient (the coordinator's current `protocolRecipient`), never
    ///      to the opener: otherwise an opener could set an unreachable `minBuy` and collect every pot after
    ///      30 days (a hidden creator fee). Buyers are unaffected: they win exactly as in the launch profile.
    function protocolRecipient(address hook) internal view returns (address) {
        return IProtocolRecipientV2(AvaxHookV2(payable(hook)).launchpad()).protocolRecipient();
    }

    /// @dev Pool `id`'s creator (the rescue recipient, as LedgerModuleBase.rescue).
    function creatorOf(address hook, PoolId id) internal view returns (address) {
        return AvaxHookV2(payable(hook)).poolInfo(id).creator;
    }

    function isDisabled(address hook, address module) internal view returns (bool) {
        return AvaxHookV2(payable(hook)).disabled(module);
    }
}
