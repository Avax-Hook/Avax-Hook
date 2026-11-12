// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BeaconModule} from "../../contracts/v2/modules/BeaconModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract BeaconModuleTest is NewModulesBase {
    BeaconModule bc;
    uint32 bcId;
    HookTokenV2 t;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        bc = new BeaconModule(address(hook));
        bcId = modules.addModule(address(bc), '{"name":"Beacon"}');
        (t, key) = _launchOne(bcId, "");
        _mockAvaxUsd(20e18);
    }

    function _ath() internal view returns (uint256 usd) {
        usd = bc.athUsd(address(t));
    }

    function test_capabilities() public view {
        assertEq(bc.capabilities(), ModuleCaps.BEFORE_SWAP);
        assertEq(bc.conflictGroups(), 0);
        assertEq(bc.isBeacon(), BeaconModule.isBeacon.selector);
        (,, bool reg) = bc.beacon(address(t));
        assertTrue(reg);
    }

    /// One observation per block, `n` blocks spread over just over HOLD_SECONDS.
    function _hold(HookTokenV2 tok, uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + bc.HOLD_SECONDS() / (n - 1) + 1);
            _routerBuy(carol, tok, 0.01 ether);
        }
    }

    function test_curveRecordsToo() public {
        HookTokenV2 t2 = _launch(_one(bcId), _oneCfg(""), 0);
        assertEq(bc.athUsd(address(t2)), 0);
        for (uint256 i; i < 5; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 4 minutes);
            vm.prank(alice);
            pad.buy{value: 0.01 ether}(address(t2), 0);
        }
        assertGt(bc.athUsd(address(t2)), 0); // a streak of 5 blocks over 15+ minutes on the curve
    }

    /// Audit M-1 (v2 rule modules): a pump only moves the ATH if it is sustained.
    function test_recordsOnlySustainedHighs() public {
        _hold(t, 6);
        _hold(t, 6);
        assertGt(_ath(), 0);

        // a pump that stands for a couple of blocks, then dumps: its peak is never recorded
        uint256 got = _routerBuy(bob, t, 1000 ether);
        _hold(t, 2);
        _routerSell(bob, t, got);
        _hold(t, 6);
        uint256 afterFlash = _ath();

        // the same pump held for a full streak (beyond the one already running) is recorded at its low
        _routerBuy(bob, t, 1000 ether);
        _hold(t, 12); // the streak that was running when the pump hit closes at its pre-pump low
        _hold(t, 12); // a streak entirely at the new level
        uint256 high = _ath();
        assertGt(high, (afterFlash * 3) / 2);

        // the ATH never falls
        _routerSell(bob, t, t.balanceOf(bob));
        _hold(t, 12);
        assertEq(_ath(), high);
    }

    function test_unpricedQuoteRecordsNothingAndNeverBlocks() public {
        vm.clearMockedCalls();
        uint256 a0 = _ath();
        vm.warp(vm.getBlockTimestamp() + 30 days); // the live feed is stale now: usdPrice reverts
        vm.roll(vm.getBlockNumber() + 1);
        uint256 got = _routerBuy(alice, t, 100 ether);
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(alice, t, 1 ether);
        assertEq(_ath(), a0);
        _routerSell(alice, t, got);
    }

    function test_configMustBeEmpty() public {
        vm.expectRevert();
        bc.validateConfig(hex"01");
        bc.validateConfig("");
    }
}
