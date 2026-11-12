// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HookModuleBase} from "../../contracts/v2/modules/HookModuleBase.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";

/// Credits `payee` a share of every buy's token output, as the pot and rewards modules do. Used to check
/// that a claim earned on the curve pays out at once on v3 — on v2 the hook's transfer to the payee hit
/// the token's curve lock, so it had to wait for graduation.
contract CreditModule is HookModuleBase {
    address public payee;
    uint16 public bps;

    constructor(address _hook, address _payee, uint16 _bps) HookModuleBase(_hook) {
        payee = _payee;
        bps = _bps;
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata) public pure override {}

    function onRegister(PoolId, address, address, address, bytes calldata) external override onlyHook {}

    function onAfterSwap(SwapContext calldata ctx) external view override onlyHook returns (Credit[] memory) {
        if (!ctx.isBuy) return new Credit[](0);
        uint256 c = (ctx.amountOut * bps) / BPS;
        return c == 0 ? new Credit[](0) : _one(payee, c);
    }
}
