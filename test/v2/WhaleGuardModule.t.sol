// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {WhaleGuardModule} from "../../contracts/v2/modules/WhaleGuardModule.sol";
import {ProbeModule} from "./V2Mocks.sol";
import {V1PortBase, MultiTrader} from "./V1PortBase.t.sol";

contract WhaleGuardModuleTest is V1PortBase {
    HookTokenV2 t50;
    PoolKey k50;
    HookTokenV2 t100;
    PoolKey k100;

    /// Graduation happens here, in its own transaction: the hook's per-transaction volume counts curve and
    /// pool buys together (a test function is one transaction), so ~800 AVAX of graduation buys in the test
    /// itself would already be over the cap.
    function setUp() public override {
        super.setUp();
        t50 = _launch(_ids1(whaleId), _cfgs1(_whaleCfg(50, 2 ether)), 100);
        t100 = _launch(_ids1(whaleId), _cfgs1(_whaleCfg(100, 2 ether)), 100);
        vm.roll(vm.getBlockNumber() + CURVE_WINDOWS); // past the curve windows, then both pools open now
        k50 = _graduate(t50);
        k100 = _graduate(t100);
    }

    // v1 test_whaleGuard
    function test_whaleGuard() public {
        (HookTokenV2 t, PoolKey memory key) = (t50, k50);
        assertTrue(whale.active(_id(key)));
        vm.expectRevert(); // wrapped by the PoolManager
        _routerBuy(bob, t, 3 ether);
        uint256 got = _routerBuy(bob, t, 2 ether);
        _routerSell(bob, t, got); // sells are never capped
        vm.roll(vm.getBlockNumber() + 51);
        assertFalse(whale.active(_id(key)));
        _routerBuy(bob, t, 10 ether); // window over
    }

    // HK-4 PoC re-run: 3 × 1 AVAX in one transaction against a 2 AVAX cap used to pass per swap.
    function test_HK4_capIsPerTransaction() public {
        HookTokenV2 t = t100;
        MultiTrader m = new MultiTrader(address(router));
        vm.deal(address(m), 10 ether);
        vm.expectRevert();
        m.buys(address(t), 1 ether, 3);
        m.buys(address(t), 1 ether, 2); // 2 AVAX in the transaction is fine
    }

    // An aggregator (no router identity) is capped the same way.
    function test_aggregatorBuysCapped() public {
        PoolKey memory key = k100;
        vm.expectRevert();
        _directBuy(key, 2.5 ether);
        _directBuy(key, 1.5 ether);
        vm.expectRevert(); // 1.5 + 1 in the same transaction
        _directBuy(key, 1 ether);
    }

    function test_conflictsWithOtherBuyCaps() public {
        ProbeModule p = new ProbeModule(address(hook), ModuleCaps.BEFORE_SWAP, ModuleCaps.GROUP_BUY_CAP);
        uint32 pid = modules.addModule(address(p), '{"name":"cap"}');
        vm.expectRevert(abi.encodeWithSelector(AvaxHookV2.ModuleConflict.selector, pid));
        this.launchExt(_ids2(whaleId, pid), _cfgs2(_whaleCfg(100, 2 ether), ""));
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs) external returns (HookTokenV2) {
        return _launch(ids, cfgs, 0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        whale.validateConfig(_whaleCfg(0, 1 ether));
        vm.expectRevert();
        whale.validateConfig(_whaleCfg(43_201, 1 ether));
        vm.expectRevert();
        whale.validateConfig(_whaleCfg(100, 0));
        whale.validateConfig(_whaleCfg(43_200, 1));
        assertEq(whale.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
        assertEq(whale.capabilities(), ModuleCaps.BEFORE_SWAP);
    }
}
