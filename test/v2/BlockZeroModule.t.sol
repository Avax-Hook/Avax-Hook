// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BlockZeroModule} from "../../contracts/v2/modules/BlockZeroModule.sol";
import {EarlyBlocksBase} from "./EarlyBlocksBase.t.sol";

contract BlockZeroModuleTest is EarlyBlocksBase {
    BlockZeroModule bz;
    uint32 bzId;

    function setUp() public override {
        super.setUp();
        bz = new BlockZeroModule(address(hook));
        bzId = modules.addModule(address(bz), '{"name":"Block zero"}');
    }

    function _cfg(uint8 blocks, uint8 poolBlocks) internal pure returns (bytes memory) {
        return abi.encode(BlockZeroModule.Config(blocks, poolBlocks));
    }

    function test_capabilities() public view {
        assertEq(bz.capabilities(), ModuleCaps.BEFORE_SWAP);
        assertEq(bz.conflictGroups(), 0);
    }

    function test_devBuyPassesOthersRefused() public {
        uint256 b0 = vm.getBlockNumber();
        HookTokenV2 t = _launchWithDevBuy(_one(bzId), _oneCfg(_cfg(3, 0)), 1 ether);
        assertGt(t.balanceOf(creator), 0);
        assertEq(bz.creatorOf(address(t)), creator);
        (bool on, uint256 until) = bz.creatorOnly(address(t));
        assertTrue(on);
        assertEq(until, b0 + 3);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlockZeroModule.CreatorOnly.selector, b0 + 3));
        pad.buy{value: 1 ether}(address(t), 0);
        // the creator can keep buying in the window, and sells are free
        _curveBuy(creator, t, 1 ether);
        _curveSell(creator, t, 1_000 ether);
        vm.roll(b0 + 2);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);
        vm.roll(b0 + 3); // window over
        (on,) = bz.creatorOnly(address(t));
        assertFalse(on);
        _curveBuy(alice, t, 1 ether);
    }

    function test_poolWindow() public {
        HookTokenV2 t = _launch(_one(bzId), _oneCfg(_cfg(1, 5)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        PoolKey memory key = _graduateN(t, 10, 0);
        uint256 open = vm.getBlockNumber();
        (bool on, uint256 until) = bz.creatorOnly(address(t));
        assertTrue(on);
        assertEq(until, open + 5);
        bytes memory err = _buyError(alice, t, 1 ether);
        assertTrue(_has(err, BlockZeroModule.CreatorOnly.selector));
        vm.expectRevert(); // aggregators carry no trader: refused too
        agg.swap(key, true, -int256(1 ether));
        _routerBuy(creator, t, 1 ether);
        // holders sell freely
        _routerSell(_holder(0), t, t.balanceOf(_holder(0)) / 2);
        vm.roll(open + 5);
        _routerBuy(alice, t, 1 ether);
        agg.swap(key, true, -int256(1 ether));
    }

    function test_poolWindowOff() public {
        HookTokenV2 t = _launch(_one(bzId), _oneCfg(_cfg(1, 0)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        PoolKey memory key = _graduateN(t, 10, 0);
        (bool on,) = bz.creatorOnly(address(t));
        assertFalse(on);
        _routerBuy(alice, t, 1 ether);
        agg.swap(key, true, -int256(1 ether));
    }

    function testFuzz_windowLength(uint8 blocks, uint8 wait) public {
        uint8 n = uint8(bound(blocks, 1, 20));
        uint256 w = bound(wait, 0, 40);
        uint256 b0 = vm.getBlockNumber();
        HookTokenV2 t = _launch(_one(bzId), _oneCfg(_cfg(n, 0)), 0);
        vm.roll(b0 + w);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        if (w < n) vm.expectRevert();
        pad.buy{value: 0.5 ether}(address(t), 0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        bz.validateConfig(_cfg(0, 0));
        vm.expectRevert();
        bz.validateConfig(_cfg(21, 0));
        vm.expectRevert();
        bz.validateConfig(_cfg(1, 21));
        bz.validateConfig(_cfg(20, 20));
    }
}
