// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

contract AutoBurnModuleTest is V1PortBase {
    function test_burnsShareOfBuyOutput() public {
        (HookTokenV2 t, PoolKey memory key) = _one(burnId, _burnCfg(200));
        (HookTokenV2 p,) = _plain();
        uint256 dead0 = t.balanceOf(DEAD);
        uint256 total0 = burn.burnOf(_id(key)).totalBurned; // curve-phase buys burned too
        uint256 got = _routerBuy(bob, t, 5 ether);
        uint256 plain = _routerBuy(bob, p, 5 ether);
        uint256 burned = t.balanceOf(DEAD) - dead0;
        assertEq(got + burned, plain);
        assertEq(burned, (plain * 200) / 10_000);
        assertEq(burn.burnOf(_id(key)).totalBurned - total0, burned);
        // sells burn nothing
        _routerSell(bob, t, got);
        assertEq(t.balanceOf(DEAD) - dead0, burned);
    }

    function test_configBounds() public {
        vm.expectRevert();
        burn.validateConfig(_burnCfg(0));
        vm.expectRevert();
        burn.validateConfig(_burnCfg(501));
        burn.validateConfig(_burnCfg(500));
    }
}
