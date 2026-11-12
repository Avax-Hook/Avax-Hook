// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITransferHook {
    function onTokenTransfer(address operator, address from, address to, uint256 amount) external;
}

/// @title HookTokenV3
/// @notice HookTokenV2 without the curve-phase transfer lock: a holder can send, burn or pool the token
///         from the moment they buy it, as on pump.fun and Pons, instead of waiting for graduation.
///
///   v2 reverted every move that was not to or from the launchpad until graduation
///   (`CurvePhaseTransfer`), so that nobody could seed or skew the Uniswap v4 pool before the launchpad
///   opened it. That is already guaranteed one level up: `AvaxHookV2.beforeInitialize` lets only its own
///   launchpad initialize a pool, and only a registered one. What the lock cost was everything else —
///   wallet-to-wallet sends, treasury sends, airdrops, burns, and claiming a module's token credits
///   earned on the curve. Those all work here. Someone may now open a pool for the token on another DEX
///   before graduation; that does not touch our pool, it only arbitrages against the curve.
///
///   Everything else is v2, including the ABI the launchpad and the UI call:
///     - fixed supply, minted once to the launchpad; no mint, tax, blacklist or pause of its own;
///     - `tradingOpen` still turns true at graduation, but it no longer gates transfers — it is the
///       "the pool is open" flag the launchpad sets and the site reads;
///     - if the pool's modules include a transfer rule, every move except mints and burns is reported to
///       AvaxHookV2 after balances update, which runs those modules (max per wallet, King of the Hill
///       "sending gives up the crown", vesting, ...). Curve-phase moves are reported too, so a holder
///       cannot sidestep a rule by sending to a second wallet before graduation. Tokens without transfer
///       rules never call out.
contract HookTokenV3 is ERC20 {
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

    /// @notice Pulls tokens into the launchpad for a curve sell — saves the holder an approve tx. Only the
    ///         launchpad can call it, and only while the curve is running: afterwards the token is an
    ///         ordinary ERC-20 that moves by allowance like any other.
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
        super._update(from, to, value);
        if (transferRules && from != address(0) && to != address(0)) {
            ITransferHook(hook).onTokenTransfer(msg.sender, from, to, value);
        }
    }
}
