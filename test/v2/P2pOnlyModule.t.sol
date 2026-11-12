// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {P2pOnlyModule} from "../../contracts/v2/modules/P2pOnlyModule.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract P2pOnlyModuleTest is ListsAccessBase {
    P2pOnlyModule pp;
    uint32 ppId;

    function setUp() public override {
        super.setUp();
        pp = new P2pOnlyModule(address(hook));
        ppId = modules.addModule(address(pp), '{"name":"P2P-only"}');
    }

    function _cfg(uint32 w) internal pure returns (bytes memory) {
        return abi.encode(P2pOnlyModule.Config(w));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(pp.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS);
        assertEq(pp.conflictGroups(), ModuleCaps.GROUP_VENUE);
        vm.expectRevert();
        pp.validateConfig(_cfg(1 hours - 1));
        vm.expectRevert();
        pp.validateConfig(_cfg(7 days + 1));
        pp.validateConfig(_cfg(7 days));
    }

    function test_curveUntouched_poolClosedForWindow() public {
        HookTokenV2 t = _launch(_one(ppId), _oneCfg(_cfg(1 days)), 0);
        _curveBuy(alice, t, 1 ether);
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        pad.sell(address(t), half, 0);
        (uint256 opensAt, bool p2p) = pp.status(address(t));
        assertEq(opensAt, 0);
        assertFalse(p2p);
        PoolKey memory key = _graduateN(t, 40, 0);
        (opensAt, p2p) = pp.status(address(t));
        assertTrue(p2p);
        assertEq(opensAt, vm.getBlockTimestamp() + 1 days);
        // pool buys and sells refused: router, direct PoolManager
        _buyReverts(bob, t, 1 ether);
        vm.expectRevert();
        _aggBuy(key, 1 ether);
        address h = _holder(0);
        uint256 bal = t.balanceOf(h);
        _sellReverts(h, t, bal / 2);
        vm.prank(h);
        t.approve(address(agg), bal / 2);
        vm.expectRevert();
        agg.sellFrom(key, address(t), h, bal / 2);
        // wallet to wallet works
        _send(t, h, carol, bal / 2);
        // after the window: normal trading
        vm.warp(opensAt);
        _routerSell(carol, t, bal / 2);
        _routerBuy(bob, t, 1 ether);
        _aggBuy(key, 1 ether);
    }
}
