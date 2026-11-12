// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BlocklistModule} from "../../contracts/v2/modules/BlocklistModule.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract BlocklistModuleTest is ListsAccessBase {
    BlocklistModule bl;
    uint32 blId;

    function setUp() public override {
        super.setUp();
        bl = new BlocklistModule(address(hook));
        blId = modules.addModule(address(bl), '{"name":"Blocklist"}');
    }

    function _list(address a, address b) internal pure returns (bytes memory) {
        address[] memory l = new address[](2);
        (l[0], l[1]) = (a, b);
        return abi.encode(BlocklistModule.Config(l));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(bl.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER); // BEFORE_SWAP: claims-bypass guard
        assertEq(bl.conflictGroups(), ModuleCaps.GROUP_RECEIVER_LIST);
        vm.expectRevert();
        bl.validateConfig(abi.encode(BlocklistModule.Config(new address[](0))));
        vm.expectRevert();
        bl.validateConfig(abi.encode(BlocklistModule.Config(new address[](201))));
        vm.expectRevert();
        bl.validateConfig(_list(bob, address(0)));
        address[] memory big = new address[](200);
        for (uint256 i; i < 200; ++i) big[i] = address(uint160(0xAA0000 + i));
        bl.validateConfig(abi.encode(BlocklistModule.Config(big)));
        // 200 entries fit in one launch
        HookTokenV2 t = _launch(_one(blId), _oneCfg(abi.encode(BlocklistModule.Config(big))), 0);
        assertTrue(bl.isBlocked(address(t), address(0xAA00C7)));
        assertEq(bl.listSize(address(t)), 200);
    }

    function test_curveAndPool() public {
        HookTokenV2 t = _launch(_one(blId), _oneCfg(_list(bob, address(agg))), 0);
        _curveBuyReverts(bob, t, 1 ether);
        _curveBuy(alice, t, 1 ether);
        assertTrue(bl.isBlocked(address(t), bob));
        assertFalse(bl.isBlocked(address(t), alice));
        PoolKey memory key = _graduateN(t, 40, 0);
        _buyReverts(bob, t, 1 ether);
        vm.expectRevert();
        _aggBuy(key, 1 ether); // the blocked aggregator contract can't receive
        uint256 got = _routerBuy(carol, t, 1 ether);
        _sendReverts(t, carol, bob, got / 2);
        _send(t, carol, alice, got / 2);
        _routerSell(alice, t, t.balanceOf(alice));
    }

    function test_plumbingCannotBeBlocked() public {
        HookTokenV2 t = _launch(_one(blId), _oneCfg(_list(address(PM), address(pad))), 0);
        assertFalse(bl.isBlocked(address(t), address(PM)));
        _graduateN(t, 40, 0);
        uint256 got = _routerBuy(alice, t, 1 ether);
        _routerSell(alice, t, got);
    }

    function testFuzz_onlyListedRefused(address who) public {
        HookTokenV2 t = _launch(_one(blId), _oneCfg(_list(bob, carol)), 0);
        bool plumbing = who == address(PM) || who == address(pad) || who == address(hook) || who == DEAD || who == address(bl);
        assertEq(bl.isBlocked(address(t), who), (who == bob || who == carol) && !plumbing);
    }
}
