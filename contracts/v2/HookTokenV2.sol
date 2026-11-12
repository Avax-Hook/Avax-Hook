// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITransferHook {
    function onTokenTransfer(address operator, address from, address to, uint256 amount) external;
}

/// @title HookTokenV2
/// @notice Fixed-supply ERC20 minted once to the launchpad. No mint, tax, blacklist or pause of its own.
///   - Until graduation the token only moves to or from the launchpad (as v1): holders trade on the
///     curve, and nobody can seed or skew the v4 pool before the launchpad opens it.
///   - If the pool's modules include a transfer rule, every move except mints and burns is reported to
///     AvaxHookV2 after balances update, which runs those modules (max per wallet, King of the Hill
///     "sending gives up the crown", vesting, ...). Tokens without transfer rules never call out.
contract HookTokenV2 is ERC20 {
    address public immutable launchpad;
    address public immutable creator;
    address public immutable hook;
    // one slot, read on every transfer
    bool public tradingOpen;
    bool public transferRules;

    string public description;
    string public image;
    string public website;
    string public twitter;
    string public telegram;

    error OnlyLaunchpad();
    error CurvePhaseTransfer();

    struct Metadata {
        string description;
        string image;
        string website;
        string twitter;
        string telegram;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        Metadata memory meta,
        address creator_,
        address launchpad_,
        address hook_,
        uint256 supply
    ) ERC20(name_, symbol_) {
        launchpad = launchpad_;
        creator = creator_;
        hook = hook_;
        description = meta.description;
        image = meta.image;
        website = meta.website;
        twitter = meta.twitter;
        telegram = meta.telegram;
        _mint(launchpad_, supply);
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    /// @notice Pulls tokens into the launchpad for a curve sell — saves the holder an approve tx.
    function curvePull(address from, uint256 amount) external onlyLaunchpad {
        if (tradingOpen) revert CurvePhaseTransfer();
        _transfer(from, launchpad, amount);
    }

    /// @notice Turns on transfer callbacks; the launchpad calls it right after registering the pool, when
    ///         one of its modules is a transfer rule. One-way.
    function enableTransferRules() external onlyLaunchpad {
        transferRules = true;
    }

    function openTrading() external onlyLaunchpad {
        tradingOpen = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool open = tradingOpen;
        if (!open && from != address(0) && from != launchpad && to != launchpad) {
            revert CurvePhaseTransfer();
        }
        super._update(from, to, value);
        if (transferRules && from != address(0) && to != address(0)) {
            ITransferHook(hook).onTokenTransfer(msg.sender, from, to, value);
        }
    }
}
