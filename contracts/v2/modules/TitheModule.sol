// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title TitheModule
/// @notice A fixed share of every pool trade goes to a recipient named at launch (a cause, a treasury, a
///         DAO): `bps` of the quote amount, from the input on buys and from the output on sells, like the
///         creator fee. It accrues as a claimable balance in AvaxHookV2; the recipient withdraws it with
///         `claim(quote, to)` (or moves it with `transferClaim`), so the recipient must be an account that
///         can make those calls.
///   - Every trade pays: bonding-curve buys and sells, and every pool swap (router or not).
///   - Recipient 0x…dEaD burns the quote instead. address(0) and address(1) (the LP-donation marker) are
///     refused.
///   - Fixed forever: nobody can change the recipient or the share after launch.
contract TitheModule is HookModuleBase {
    struct Config {
        address recipient;
        uint16 bps; // of each trade's quote amount: 0.01% .. 5%
    }

    struct Rule {
        Config cfg;
        bool registered;
    }

    uint16 public constant MAX_BPS = 500;

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.recipient == address(0) || c.recipient == ModuleCaps.LP_DONATE) revert BadConfig();
        if (c.bps == 0 || c.bps > MAX_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.registered = true;
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _tithe(_rules[ctx.poolId].cfg, ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external view override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _tithe(_rules[ctx.poolId].cfg, ctx.amountOut);
    }

    function tithe(address token) external view returns (address recipient, uint16 bps) {
        Config memory c = _rules[poolOf[token]].cfg;
        return (c.recipient, c.bps);
    }

    function _tithe(Config memory c, uint256 amount) internal pure returns (Credit[] memory) {
        uint256 t = (amount * c.bps) / BPS;
        if (t == 0) return new Credit[](0);
        return _one(c.recipient, t);
    }
}
