// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LastBuyerPotModule} from "../../modules/LastBuyerPotModule.sol";
import {PoolsPotLib} from "./PoolsPotLib.sol";

/// @title LastBuyerPotPoolsModule
/// @notice LastBuyerPotModule for the existing-token (pools) profile, where one token can have many pools:
///   - `rescuePool(id)` replaces `rescue(token)` (which resolved only the token's newest pool, audit L-1);
///   - `potBps` is capped at 2% (audit L-3);
///   - an orphaned pot (no leader for 30 days) goes to the protocol recipient, not the pool's opener (L-3).
contract LastBuyerPotPoolsModule is LastBuyerPotModule {
    error UseRescuePool();

    constructor(address _hook) LastBuyerPotModule(_hook) {}

    function validateConfig(bytes calldata config) public pure override {
        super.validateConfig(config);
        if (abi.decode(config, (Config)).potBps > PoolsPotLib.MAX_POT_BPS) revert BadConfig();
    }

    /// @notice After the registry disabled this module, pays pool `id`'s pot to that pool's creator (as
    ///         LedgerModuleBase.rescue, but by pool, so every pool of a token is reachable). Anyone.
    function rescuePool(PoolId id) external {
        if (!PoolsPotLib.isDisabled(hook, address(this))) revert NotDisabled();
        _reconcile();
        (address quote, uint256 amount) = _takeShare(id);
        if (amount == 0) return;
        address creator = PoolsPotLib.creatorOf(hook, id);
        _payClaim(quote, creator, amount);
        emit Rescued(id, creator, quote, amount);
    }

    /// @dev Token-based rescue is ambiguous with several pools per token.
    function rescue(address) external pure override {
        revert UseRescuePool();
    }

    /// @dev As LastBuyerPotModule._winner, but an orphaned pot goes to the protocol recipient.
    function _winner(Pot storage p) internal view override returns (address) {
        address leader = p.leader;
        if (leader == address(0)) {
            return block.timestamp >= uint256(p.lastBuyAt) + TIMER_ORPHAN_SECONDS
                ? PoolsPotLib.protocolRecipient(hook)
                : address(0);
        }
        return block.timestamp >= uint256(p.lastBuyAt) + p.timerSeconds ? leader : address(0);
    }
}
