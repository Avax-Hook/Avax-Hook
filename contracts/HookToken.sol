// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HookToken
/// @notice Fixed-supply ERC20 minted once to the launchpad. No mint, tax, blacklist or pause.
/// @dev Until graduation the token only moves to or from the launchpad: holders trade on the
///      bonding curve, and nobody can seed or skew the Pharaoh pool before the launchpad opens it.
///      `openTrading` is one-way and only the launchpad can call it.
contract HookToken is ERC20 {
    address public immutable launchpad;
    address public immutable creator;
    bool public tradingOpen;

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
        uint256 supply
    ) ERC20(name_, symbol_) {
        launchpad = launchpad_;
        creator = creator_;
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

    function openTrading() external onlyLaunchpad {
        tradingOpen = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!tradingOpen && from != address(0) && from != launchpad && to != launchpad) {
            revert CurvePhaseTransfer();
        }
        super._update(from, to, value);
    }
}
