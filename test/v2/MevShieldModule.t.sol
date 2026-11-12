// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {MevShieldModule} from "../../contracts/v2/modules/MevShieldModule.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

contract MevShieldModuleTest is V1PortBase {
    // v1 test_mevShield, plus sells and the window end.
    function test_mevShield() public {
        (HookTokenV2 t, PoolKey memory key) = _one(mevId, _mevCfg(50, 5 gwei));
        vm.fee(25 gwei);
        vm.txGasPrice(31 gwei); // 6 gwei priority
        vm.expectRevert(); // wrapped by the PoolManager
        _routerBuy(bob, t, 1 ether);
        vm.txGasPrice(26 gwei);
        uint256 got = _routerBuy(bob, t, 1 ether);

        vm.txGasPrice(31 gwei); // a bribing sell is refused too (BLOCKS_SELLS)
        vm.startPrank(bob);
        t.approve(address(router), got);
        vm.expectRevert();
        router.sell(address(t), got, 0, block.timestamp, "");
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 50);
        assertFalse(mev.active(_id(key)));
        _routerSell(bob, t, got); // window over
    }

    // L-3: the cap can't go below 5 gwei of priority, nor the window past MAX_MEV_BLOCKS.
    function test_L3_bounds() public {
        vm.expectRevert();
        mev.validateConfig(_mevCfg(300, 2 gwei));
        mev.validateConfig(_mevCfg(300, 5 gwei));
        uint32 tooLong = mev.MAX_MEV_BLOCKS() + 1;
        vm.expectRevert();
        mev.validateConfig(_mevCfg(tooLong, 5 gwei));
        mev.validateConfig(_mevCfg(1_800, 5 gwei));
        vm.expectRevert();
        mev.validateConfig(_mevCfg(0, 5 gwei));
        assertTrue(mev.capabilities() & ModuleCaps.BLOCKS_SELLS != 0);
    }
}
