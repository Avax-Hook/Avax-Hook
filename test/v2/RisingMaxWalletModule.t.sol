// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {RisingMaxWalletModule} from "../../contracts/v2/modules/RisingMaxWalletModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract RisingMaxWalletModuleTest is NewModulesBase {
    RisingMaxWalletModule rm;
    uint32 rmId;
    HookTokenV2 t;
    PoolKey key;
    uint256 launchTs;

    uint256 constant PCT = 10_000_000 ether; // 1% of supply

    function setUp() public override {
        super.setUp();
        rm = new RisingMaxWalletModule(address(hook));
        rmId = modules.addModule(address(rm), '{"name":"Rising max wallet"}');
        launchTs = vm.getBlockTimestamp();
        // 1% at launch, +1% per hour; the curve fills at launch time with buys under 1%
        (t, key) = _launchCapped(rmId, _cfg(100, 0, 100, 1 hours), 9_000_000 ether, 0);
    }

    function _cfg(uint16 start, uint8 mode, uint16 step, uint32 interval) internal pure returns (bytes memory) {
        return abi.encode(RisingMaxWalletModule.Config(start, mode, step, interval));
    }

    function _cap(HookTokenV2 tok) internal view returns (uint256 c) {
        (c,,) = rm.currentCap(address(tok));
    }

    function test_capabilities() public view {
        assertEq(rm.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER);
        assertEq(rm.conflictGroups(), ModuleCaps.GROUP_HOLDING_CAP);
        assertTrue(t.transferRules());
    }

    function test_linearRise() public {
        (uint256 cap, uint256 nextAt, uint256 freeAt) = rm.currentCap(address(t));
        assertEq(cap, PCT);
        assertEq(nextAt, launchTs + 1 hours);
        assertEq(freeAt, launchTs + 99 hours);
        bytes memory err = _buyError(alice, t, 100 ether); // ~1.5%
        assertTrue(_has(err, RisingMaxWalletModule.MaxWalletExceeded.selector));
        vm.warp(launchTs + 1 hours);
        assertEq(_cap(t), 2 * PCT);
        uint256 a = _routerBuy(alice, t, 100 ether);
        assertGt(a, PCT);
        vm.warp(launchTs + 2 hours - 1);
        assertEq(_cap(t), 2 * PCT);
        vm.warp(launchTs + 50 hours);
        assertEq(_cap(t), 51 * PCT);
        vm.warp(launchTs + 99 hours); // 100%: no cap any more
        (cap, nextAt,) = rm.currentCap(address(t));
        assertEq(cap, 0);
        assertEq(nextAt, 0);
        assertEq(rm.capAt(address(t), launchTs + 98 hours), 99 * PCT);
        assertEq(rm.capAt(address(t), launchTs), PCT);
    }

    function test_doublingMode_curvePhase() public {
        uint256 ts = vm.getBlockTimestamp();
        HookTokenV2 t2 = _launch(_one(rmId), _oneCfg(_cfg(100, 1, 0, 1 days)), 0);
        (,, uint256 freeAt) = rm.currentCap(address(t2));
        assertEq(freeAt, ts + 7 days); // 1 -> 2 -> 4 -> ... -> 128% after 7 doublings
        vm.prank(alice);
        try pad.buy{value: 20 ether}(address(t2), 0) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, RisingMaxWalletModule.MaxWalletExceeded.selector));
        }
        vm.warp(ts + 3 days); // 8%
        assertEq(_cap(t2), 8 * PCT);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t2), 0);
        assertGt(t2.balanceOf(alice), PCT);
        assertEq(rm.capAt(address(t2), ts + 6 days), 64 * PCT);
        assertEq(rm.capAt(address(t2), ts + 7 days), 0);
    }

    function test_transfersCapped_sellsFree() public {
        address h0 = _holder(0);
        address h1 = _holder(1);
        uint256 b0 = t.balanceOf(h0);
        uint256 b1 = t.balanceOf(h1);
        assertGt(b0 + b1, PCT);
        vm.prank(h0);
        vm.expectRevert(abi.encodeWithSelector(RisingMaxWalletModule.MaxWalletExceeded.selector, h1, b0 + b1, PCT));
        t.transfer(h1, b0);
        _routerSell(h1, t, b1);
        vm.prank(h0);
        t.transfer(h1, b0); // h1 sold out: fits now
        vm.warp(launchTs + 1 hours);
        uint256 b2 = t.balanceOf(_holder(2));
        vm.prank(_holder(2));
        t.transfer(h1, b2); // ~1.8% under the 2% cap
    }

    /// Claims bypass guard (2026-11-12): while there is a cap, aggregator buys on the PoolManager are refused
    /// with RouterOnly; once the cap is gone (100% after 99 hours) they work again, any size.
    function test_aggregatorCountsAsWallet() public {
        _aggSwapRouterOnly(key, true, -int256(150 ether));
        _aggSwapRouterOnly(key, true, -int256(5 ether));
        vm.warp(launchTs + 99 hours);
        agg.swap(key, true, -int256(150 ether));
        assertGt(t.balanceOf(address(agg)), 0);
    }

    function test_creatorNotExempt() public {
        vm.deal(creator, 1_000 ether);
        bytes memory err = _buyError(creator, t, 100 ether);
        assertTrue(_has(err, RisingMaxWalletModule.MaxWalletExceeded.selector));
    }

    function test_configBounds() public {
        vm.expectRevert();
        rm.validateConfig(_cfg(9, 0, 100, 1 hours));
        vm.expectRevert();
        rm.validateConfig(_cfg(5_001, 0, 100, 1 hours));
        vm.expectRevert();
        rm.validateConfig(_cfg(100, 0, 0, 1 hours)); // linear needs a step
        vm.expectRevert();
        rm.validateConfig(_cfg(100, 0, 5_001, 1 hours));
        vm.expectRevert();
        rm.validateConfig(_cfg(100, 1, 100, 1 hours)); // doubling takes no step
        vm.expectRevert();
        rm.validateConfig(_cfg(100, 2, 0, 1 hours)); // unknown mode
        vm.expectRevert();
        rm.validateConfig(_cfg(100, 0, 100, 59));
        vm.expectRevert();
        rm.validateConfig(_cfg(100, 0, 100, 7 days + 1));
        vm.expectRevert();
        rm.validateConfig(_cfg(10, 0, 1, 1 days)); // 9,990 days to 100%: over 365 days
        rm.validateConfig(_cfg(10, 0, 30, 1 days)); // 333 days
        rm.validateConfig(_cfg(10, 1, 0, 7 days)); // 10 doublings x 7 days
        rm.validateConfig(_cfg(5_000, 0, 5_000, 60));
    }

    function test_onlyHook() public {
        vm.expectRevert(abi.encodeWithSignature("OnlyHook()"));
        rm.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }

    /// The cap never falls over time, and is gone for good once it reaches 100%.
    function testFuzz_capNeverFalls(uint16 start, uint16 step, uint32 interval, uint32 a, uint32 b) public {
        start = uint16(bound(start, 10, 5_000));
        interval = uint32(bound(interval, 60, 7 days));
        step = uint16(bound(step, 1, 5_000));
        if (((10_000 - uint256(start) + step - 1) / step) * interval > 365 days) return;
        uint256 ts = vm.getBlockTimestamp();
        HookTokenV2 t2 = _launch(_one(rmId), _oneCfg(_cfg(start, 0, step, interval)), 0);
        uint256 ta = ts + bound(a, 0, 400 days);
        uint256 tb = ta + bound(b, 0, 400 days);
        uint256 ca = rm.capAt(address(t2), ta);
        uint256 cb = rm.capAt(address(t2), tb);
        if (ca == 0) assertEq(cb, 0);
        else if (cb != 0) assertGe(cb, ca);
        assertEq(rm.capAt(address(t2), ts + 366 days), 0);
    }
}
