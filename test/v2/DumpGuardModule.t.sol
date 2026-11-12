// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {DumpGuardModule} from "../../contracts/v2/modules/DumpGuardModule.sol";
import {V1PortBase, MultiTrader} from "./V1PortBase.t.sol";

contract DumpGuardModuleTest is V1PortBase {
    // v1 test_dumpGuard: 0.1% of supply = 1M tokens per transaction.
    function test_dumpGuard() public {
        (HookTokenV2 t, PoolKey memory key) = _one(dumpId, _dumpCfg(50, 10));
        _routerBuy(bob, t, 30 ether);
        vm.startPrank(bob);
        t.approve(address(router), type(uint256).max);
        vm.expectRevert(); // wrapped by the PoolManager
        router.sell(address(t), 2_000_000 ether, 0, block.timestamp, "");
        router.sell(address(t), 1_000_000 ether, 0, block.timestamp, "");
        vm.expectRevert(); // the transaction already sold its 1M
        router.sell(address(t), 1 ether, 0, block.timestamp, "");
        vm.stopPrank();
        (uint256 cap, bool active) = dump.maxSell(_id(key));
        assertEq(cap, 1_000_000 ether);
        assertTrue(active);
        vm.roll(vm.getBlockNumber() + 50);
        vm.prank(bob);
        router.sell(address(t), 3_000_000 ether, 0, block.timestamp, ""); // window over
    }

    // HK-4 PoC re-run: splitting a dump into several sells in one transaction doesn't pass the cap.
    function test_HK4_capIsPerTransaction() public {
        (HookTokenV2 t,) = _one(dumpId, _dumpCfg(100, 10));
        MultiTrader m = new MultiTrader(address(router));
        _routerBuy(bob, t, 30 ether);
        vm.prank(bob);
        t.transfer(address(m), 3_000_000 ether);
        vm.expectRevert();
        m.sells(address(t), 600_000 ether, 2);
        m.sells(address(t), 500_000 ether, 2);
    }

    // Refusing sells is the rule: it declares BLOCKS_SELLS, so the hook lets its revert stand on the sell
    // path, also for aggregator sells straight into the PoolManager.
    function test_blocksSellsDeclaredAndAggregatorSellsCapped() public {
        assertTrue(dump.capabilities() & ModuleCaps.BLOCKS_SELLS != 0);
        assertEq(dump.conflictGroups(), ModuleCaps.GROUP_SELL_CAP);
        (HookTokenV2 t, PoolKey memory key) = _one(dumpId, _dumpCfg(100, 10));
        _routerBuy(bob, t, 30 ether);
        vm.prank(bob);
        t.approve(address(agg), type(uint256).max);
        vm.expectRevert();
        agg.sellFrom(key, address(t), bob, 1_500_000 ether);
        agg.sellFrom(key, address(t), bob, 900_000 ether);
    }

    function test_configBounds() public {
        vm.expectRevert();
        dump.validateConfig(_dumpCfg(0, 10));
        vm.expectRevert();
        dump.validateConfig(_dumpCfg(43_201, 10));
        vm.expectRevert();
        dump.validateConfig(_dumpCfg(100, 0));
        vm.expectRevert();
        dump.validateConfig(_dumpCfg(100, 1_001));
        dump.validateConfig(_dumpCfg(43_200, 1_000));
    }
}
