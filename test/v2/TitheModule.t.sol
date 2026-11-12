// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {TitheModule} from "../../contracts/v2/modules/TitheModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract TitheModuleTest is NewModulesBase {
    TitheModule ti;
    uint32 tiId;
    HookTokenV2 t;
    PoolKey key;
    address cause = makeAddr("cause");

    function setUp() public override {
        super.setUp();
        ti = new TitheModule(address(hook));
        tiId = modules.addModule(address(ti), '{"name":"Tithe"}');
        (t, key) = _launchOne(tiId, abi.encode(TitheModule.Config(cause, 100))); // 1%
    }

    function test_capabilities() public view {
        assertEq(ti.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        assertEq(ti.conflictGroups(), 0);
        (address r, uint16 bps) = ti.tithe(address(t));
        assertEq(r, cause);
        assertEq(bps, 100);
    }

    function test_titheOnBuysAndSells() public {
        uint256 c00 = hook.claimable(cause, NATIVE); // the curve already paid its tithe
        assertApproxEqRel(c00, uint256(pad.getLaunch(address(t)).target) / 100, 0.02e18);
        uint256 got = _routerBuy(alice, t, 10 ether);
        assertEq(hook.claimable(cause, NATIVE) - c00, 0.1 ether); // 1% of the buy input
        uint256 out = _routerSell(alice, t, got);
        // out = gross · (1 - 0.3% protocol - 1% tithe)
        uint256 gross = (out * 10_000) / (10_000 - 30 - 100);
        assertApproxEqAbs(hook.claimable(cause, NATIVE) - c00 - 0.1 ether, gross / 100, 1e12);
        // aggregator trades pay too
        uint256 c0 = hook.claimable(cause, NATIVE);
        agg.swap(key, true, -int256(5 ether));
        assertEq(hook.claimable(cause, NATIVE) - c0, 0.05 ether);
        // the recipient withdraws
        uint256 owed = hook.claimable(cause, NATIVE);
        vm.prank(cause);
        hook.claim(NATIVE, cause);
        assertEq(cause.balance, owed);
    }

    function test_curveTithe() public {
        HookTokenV2 t2 = _launch(_one(tiId), _oneCfg(abi.encode(TitheModule.Config(cause, 100))), 0);
        uint256 c0 = hook.claimable(cause, NATIVE);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t2), 0);
        assertEq(hook.claimable(cause, NATIVE) - c0, 0.1 ether);
        uint256 bal = t2.balanceOf(alice);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        pad.sell(address(t2), bal, 0);
        uint256 out = alice.balance - b0;
        uint256 gross = (out * 10_000) / (10_000 - 30 - 100);
        assertApproxEqAbs(hook.claimable(cause, NATIVE) - c0 - 0.1 ether, gross / 100, 1e12);
        // claimable from the curve phase already (quote is held by the hook)
        uint256 owed = hook.claimable(cause, NATIVE);
        vm.prank(cause);
        hook.claim(NATIVE, cause);
        assertEq(cause.balance, owed);
    }

    function test_burnRecipient() public {
        (HookTokenV2 t2,) = _launchOne(tiId, abi.encode(TitheModule.Config(DEAD, 50)));
        uint256 d0 = DEAD.balance;
        _routerBuy(alice, t2, 10 ether);
        assertEq(DEAD.balance - d0, 0.05 ether);
    }

    function test_configBounds() public {
        vm.expectRevert();
        ti.validateConfig(abi.encode(TitheModule.Config(address(0), 100)));
        vm.expectRevert();
        ti.validateConfig(abi.encode(TitheModule.Config(address(1), 100)));
        vm.expectRevert();
        ti.validateConfig(abi.encode(TitheModule.Config(cause, 0)));
        vm.expectRevert();
        ti.validateConfig(abi.encode(TitheModule.Config(cause, 501)));
        ti.validateConfig(abi.encode(TitheModule.Config(cause, 500)));
    }
}
