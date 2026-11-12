// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BreathingCapModule} from "../../contracts/v2/modules/BreathingCapModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// forge-config: default.isolate = true
contract BreathingCapModuleTest is NewModulesBase {
    BreathingCapModule br;
    uint32 brId;
    HookTokenV2 t;
    PoolKey key;
    uint256 opened;

    uint256 constant BASE = 20_000_000 ether; // 2%

    function setUp() public override {
        super.setUp();
        br = new BreathingCapModule(address(hook));
        brId = modules.addModule(address(br), '{"name":"Breathing cap"}');
        // the cap runs on the curve too (the breath starts at launch): fill it with buys under base
        (t, key) = _launchCapped(brId, _cfg(200, 6000, 50, 300), (BASE * 95) / 100, 0);
        opened = hook.launchedAt(_id(key));
    }

    function _cfg(uint16 base, uint16 swing, uint16 floor, uint32 cycle) internal pure returns (bytes memory) {
        return abi.encode(BreathingCapModule.Config(base, swing, floor, cycle));
    }

    function test_capabilities() public view {
        assertEq(br.capabilities(), ModuleCaps.AFTER_SWAP);
        assertEq(br.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
    }

    function test_breathes() public view {
        assertEq(br.capAt(address(t), opened), BASE);
        assertEq(br.capAt(address(t), opened + 75), (BASE * 16) / 10); // inhale: +60%
        assertApproxEqAbs(br.capAt(address(t), opened + 150), BASE, 1e9);
        assertEq(br.capAt(address(t), opened + 225), (BASE * 4) / 10); // exhale: -60%
        assertEq(br.capAt(address(t), opened + 300), BASE);
        assertApproxEqRel(br.capAt(address(t), opened + 25), (BASE * 13) / 10, 1e14); // 30 deg: sin = 1/2
        assertApproxEqRel(br.capAt(address(t), opened + 50), BASE + (BASE * 6 * 866025403784438647) / 1e19, 1e14); // 60 deg
    }

    function test_floorHolds() public {
        HookTokenV2 t2 = _launch(_one(brId), _oneCfg(_cfg(200, 10_000, 50, 300)), 0);
        uint256 o2 = vm.getBlockTimestamp();
        assertEq(br.capAt(address(t2), o2 + 225), 5_000_000 ether); // base·(1-100%) = 0 -> floor
        for (uint256 s; s < 300; s += 3) {
            assertGe(br.capAt(address(t2), o2 + s), 5_000_000 ether);
            assertLe(br.capAt(address(t2), o2 + s), 2 * BASE);
        }
    }

    function test_buysFollowTheBreath() public {
        vm.warp(opened + 225); // exhale: cap 0.8%
        bytes memory err = _buyError(alice, t, 60 ether); // ~1.2%
        assertTrue(_has(err, BreathingCapModule.BuyCapExceeded.selector));
        vm.warp(opened + 300 + 75); // next inhale: cap 3.2%
        uint256 got = _routerBuy(alice, t, 60 ether);
        assertGt(got, (BASE * 4) / 10);
        // sells are never capped
        address h = _holder(0);
        _routerSell(h, t, t.balanceOf(h));
    }

    function test_splitBuysCountTogether() public {
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 100 ether);
        try m.buyTwice{value: 120 ether}(address(t), 60 ether, 60 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, BreathingCapModule.BuyCapExceeded.selector));
        }
    }

    function test_curveBuysAreCapped() public {
        HookTokenV2 t2 = _launch(_one(brId), _oneCfg(_cfg(200, 6000, 50, 300)), 0);
        vm.prank(alice);
        vm.expectRevert(); // ~8% of supply in one curve buy
        pad.buy{value: 20 ether}(address(t2), 0);
        vm.prank(alice);
        pad.buy{value: 4 ether}(address(t2), 0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        br.validateConfig(_cfg(9, 6000, 5, 300));
        vm.expectRevert();
        br.validateConfig(_cfg(20, 99, 5, 300));
        vm.expectRevert();
        br.validateConfig(_cfg(20, 10_001, 5, 300));
        vm.expectRevert();
        br.validateConfig(_cfg(20, 6000, 21, 300));
        vm.expectRevert();
        br.validateConfig(_cfg(20, 6000, 5, 59));
        vm.expectRevert();
        br.validateConfig(_cfg(20, 6000, 5, 7 days + 1));
        br.validateConfig(_cfg(1000, 10_000, 1, 7 days));
    }
}
