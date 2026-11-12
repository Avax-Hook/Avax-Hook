// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title PartnerFeeModule
/// @notice Pays an integration partner (a launch bot such as Berry) a share of every trade of the tokens
///         launched through it: `bps` of the quote amount, from the input on buys and from the output on sells,
///         like the creator fee and Tithe. It accrues as a claimable balance in AvaxHookV2 under the partner's
///         payout address, which withdraws it with `claim(quote, to)`.
///   - Partners are registered by the owner (the Safe): id, payout address, highest share. A launch must name
///     an active partner and a share within its maximum and MAX_BPS, or it reverts.
///   - The partner (not the owner) moves its payout address, in two steps (propose, then accept from the
///     new address). Credits follow the current payout; balances already credited stay with the old one.
///   - Deactivating a partner only stops new launches; its existing tokens keep paying it.
///   - Fixed forever per token: nobody can change a launched token's partner or share.
///   - Every trade pays: bonding-curve buys and sells and every pool swap (router or not). Identity-neutral.
contract PartnerFeeModule is HookModuleBase, Ownable {
    struct Config {
        bytes32 partnerId;
        uint16 bps; // of each trade's quote amount: 0.01% .. partner max (≤ 1%)
    }

    struct Partner {
        address payout;
        uint16 maxFeeBps;
        bool active;
    }

    uint16 public constant MAX_BPS = 100;

    mapping(bytes32 => Partner) public partners;
    /// @notice Payout address a partner proposed, waiting for `acceptPartnerPayout` from it.
    mapping(bytes32 => address) public pendingPayout;
    mapping(PoolId => Config) internal _cfg;
    mapping(address => PoolId) public poolOf;

    event PartnerRegistered(bytes32 indexed id, address payout, uint16 maxFeeBps);
    event PartnerActive(bytes32 indexed id, bool active);
    event PartnerPayoutProposed(bytes32 indexed id, address newPayout);
    event PartnerPayoutChanged(bytes32 indexed id, address oldPayout, address newPayout);

    error UnknownPartner();
    error InactivePartner();
    error NotPayout();

    constructor(address _hook, address _owner) HookModuleBase(_hook) Ownable(_owner) {}

    // ---------------------------------------------------------------- partners

    /// @notice Adds a partner, or updates an existing one's maximum share (its payout stays the partner's).
    function registerPartner(bytes32 id, address payout, uint16 maxFeeBps) external onlyOwner {
        if (id == bytes32(0) || maxFeeBps == 0 || maxFeeBps > MAX_BPS) revert BadConfig();
        Partner storage p = partners[id];
        if (p.payout == address(0)) {
            if (payout == address(0) || payout == ModuleCaps.LP_DONATE) revert BadConfig();
            p.payout = payout;
        } else if (payout != p.payout) {
            revert BadConfig();
        }
        p.maxFeeBps = maxFeeBps;
        p.active = true;
        emit PartnerRegistered(id, p.payout, maxFeeBps);
    }

    /// @notice Stops (or resumes) new launches with this partner; launched tokens keep paying it.
    function setPartnerActive(bytes32 id, bool active) external onlyOwner {
        if (partners[id].payout == address(0)) revert UnknownPartner();
        partners[id].active = active;
        emit PartnerActive(id, active);
    }

    function setPartnerPayout(bytes32 id, address newPayout) external {
        if (msg.sender != partners[id].payout) revert NotPayout();
        if (newPayout == address(0) || newPayout == ModuleCaps.LP_DONATE) revert BadConfig();
        pendingPayout[id] = newPayout;
        emit PartnerPayoutProposed(id, newPayout);
    }

    function acceptPartnerPayout(bytes32 id) external {
        if (msg.sender != pendingPayout[id]) revert NotPayout();
        address old = partners[id].payout;
        partners[id].payout = msg.sender;
        delete pendingPayout[id];
        emit PartnerPayoutChanged(id, old, msg.sender);
    }

    // ---------------------------------------------------------------- module

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public view override {
        Config memory c = abi.decode(config, (Config));
        Partner memory p = partners[c.partnerId];
        if (p.payout == address(0)) revert UnknownPartner();
        if (!p.active) revert InactivePartner();
        if (c.bps == 0 || c.bps > p.maxFeeBps) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        if (_cfg[id].bps != 0) revert AlreadyRegistered();
        _cfg[id] = abi.decode(config, (Config));
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _fee(_cfg[ctx.poolId], ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external view override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _fee(_cfg[ctx.poolId], ctx.amountOut);
    }

    /// @notice The partner and share a token was launched with (zero for tokens without this module).
    function partnerOf(address token) external view returns (bytes32 partnerId, uint16 partnerFeeBps) {
        Config memory c = _cfg[poolOf[token]];
        return (c.partnerId, c.bps);
    }

    function _fee(Config memory c, uint256 amount) internal view returns (Credit[] memory) {
        uint256 f = (amount * c.bps) / BPS;
        if (f == 0) return new Credit[](0);
        return _one(partners[c.partnerId].payout, f);
    }
}
