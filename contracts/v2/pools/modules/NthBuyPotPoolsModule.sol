// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {NthBuyPotModule} from "../../modules/NthBuyPotModule.sol";
import {PoolsPotLib} from "./PoolsPotLib.sol";

/// @title NthBuyPotPoolsModule
/// @notice NthBuyPotModule for the existing-token (pools) profile, where one token can have many pools:
///   - `rescuePool(id)` replaces `rescue(token)` (which resolved only the token's newest pool, audit L-1);
///   - `potBps` is capped at 2% (audit L-3);
///   - an orphaned pot (no qualifying buy for 30 days) goes to the protocol recipient, not the opener (L-3).
contract NthBuyPotPoolsModule is NthBuyPotModule {
    error UseRescuePool();

    constructor(address _hook) NthBuyPotModule(_hook) {}

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

    /// @notice Pays a pot that had no qualifying buy for ORPHAN_SECONDS to the protocol recipient (not the
    ///         opener, see PoolsPotLib). Anyone.
    function settle(PoolId id) external override {
        _reconcile();
        Pot storage p = _pots[id];
        uint256 held = p.pot;
        if (held == 0 || block.timestamp < uint256(p.lastBuyAt) + ORPHAN_SECONDS) return;
        address to = PoolsPotLib.protocolRecipient(hook);
        p.pot = 0;
        p.totalPaid += uint96(held);
        _payClaim(p.quote, to, held);
        emit OrphanPotPaid(id, to, held);
    }
}
