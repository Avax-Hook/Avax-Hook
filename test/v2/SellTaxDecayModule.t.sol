// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

contract SellTaxDecayModuleTest is V1PortBase {
    // v1 test_sellTaxDecays
    function test_sellTaxDecays() public {
        (, PoolKey memory key) = _one(sellTaxId, _sellTaxCfg(100, 100_000));
        PoolId id = _id(key);
        assertEq(sellTax.currentSellTax(id), 100_000);
        vm.roll(vm.getBlockNumber() + 50);
        assertEq(sellTax.currentSellTax(id), 50_000);
        vm.roll(vm.getBlockNumber() + 60);
        assertEq(sellTax.currentSellTax(id), 0);
    }

    function test_earlySellsPayMoreBuysDont() public {
        (HookTokenV2 t,) = _one(sellTaxId, _sellTaxCfg(100, 100_000));
        (HookTokenV2 p,) = _plain();
        // same pool state: a buy pays nothing extra
        assertEq(_routerBuy(bob, t, 5 ether), _routerBuy(bob, p, 5 ether));
        uint256 amt = t.balanceOf(bob) / 2;
        uint256 taxed = _routerSell(bob, t, amt);
        uint256 plain = _routerSell(bob, p, amt);
        // ~10% extra LP fee at open
        assertApproxEqRel(taxed, (plain * 897_000) / 997_000, 0.01e18);
    }

    function test_configBounds() public {
        vm.expectRevert();
        sellTax.validateConfig(_sellTaxCfg(0, 1));
        vm.expectRevert();
        sellTax.validateConfig(_sellTaxCfg(43_201, 1));
        vm.expectRevert();
        sellTax.validateConfig(_sellTaxCfg(100, 0));
        vm.expectRevert();
        sellTax.validateConfig(_sellTaxCfg(100, 200_001));
        sellTax.validateConfig(_sellTaxCfg(43_200, 200_000));
        assertEq(sellTax.capabilities() & ModuleCaps.BLOCKS_SELLS, 0); // a fee, never a refusal
    }
}
