// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

contract VolatilityFeeModuleTest is V1PortBase {
    // v1 test_volatilityFee (two identical pools instead of a snapshot).
    function test_volatilityFee() public {
        (HookTokenV2 a, PoolKey memory ka) = _one(volId, _volCfg(10, 50_000));
        (HookTokenV2 b,) = _one(volId, _volCfg(10, 50_000));
        _routerBuy(bob, a, 5 ether);
        assertGt(vol.currentVolFee(_id(ka)), 0);
        uint256 sameBlock = _routerBuy(bob, a, 5 ether); // price already moved this block: extra fee
        _routerBuy(bob, b, 5 ether);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 nextBlock = _routerBuy(bob, b, 5 ether); // fresh block: no volatility fee
        assertLt(sameBlock, nextBlock);
    }

    function test_feeCappedAtCeiling() public {
        (HookTokenV2 a, PoolKey memory ka) = _one(volId, _volCfg(1_000, 5_000));
        _routerBuy(bob, a, 30 ether);
        assertEq(vol.currentVolFee(_id(ka)), 5_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        vol.validateConfig(_volCfg(0, 1));
        vm.expectRevert();
        vol.validateConfig(_volCfg(1, 0));
        vm.expectRevert();
        vol.validateConfig(_volCfg(1, 50_001));
        vol.validateConfig(_volCfg(65_535, 50_000));
    }
}
