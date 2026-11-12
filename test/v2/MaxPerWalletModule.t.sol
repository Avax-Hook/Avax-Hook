// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {MaxPerWalletModule} from "../../contracts/v2/modules/MaxPerWalletModule.sol";
import {V2Base} from "./V2Base.t.sol";

/// Transfer-level rule enforcement through HookTokenV2 -> AvaxHookV2 -> module.
contract MaxPerWalletModuleTest is V2Base {
    uint256 constant CAP = 50_000_000 ether; // 5% of 1B

    function _launchMpw(uint32 duration) internal returns (HookTokenV2 t) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = mpwId;
        cfgs[0] = _mpwCfg(500, duration);
        t = _launch(ids, cfgs, 0);
    }

    /// Graduates with many small curve buys (each wallet stays under 5%).
    function _graduateSmall(HookTokenV2 t) internal returns (PoolKey memory key) {
        uint256 chunk = uint256(pad.getLaunch(address(t)).target) / 80;
        for (uint256 i; i < 200 && !pad.getLaunch(address(t)).complete; ++i) {
            address w = address(uint160(0xC0C000 + i));
            vm.deal(w, chunk * 2);
            vm.prank(w);
            pad.buy{value: chunk}(address(t), 0);
        }
        assertTrue(pad.getLaunch(address(t)).graduated);
        key = pad.poolKey(address(t));
    }

    function test_curveBuyOverCapReverts() public {
        HookTokenV2 t = _launchMpw(0);
        assertTrue(t.transferRules());
        uint256 big = uint256(pad.getLaunch(address(t)).target) / 4;
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: big}(address(t), 0);
        vm.prank(alice);
        pad.buy{value: big / 20}(address(t), 0);
        assertLe(t.balanceOf(alice), CAP);
    }

    function test_poolBuyAndTransferEnforced_sellsFree() public {
        HookTokenV2 t = _launchMpw(1 days);
        _graduateSmall(t);
        // one big buy over the cap reverts
        vm.prank(alice);
        vm.expectRevert();
        router.buy{value: 500 ether}(address(t), 500 ether, 0, address(0), block.timestamp, "");
        // two wallets near the cap can't merge
        uint256 a = _routerBuy(alice, t, 200 ether);
        _routerBuy(bob, t, 200 ether);
        assertLe(a, CAP);
        assertGt(a + t.balanceOf(bob), CAP);
        uint256 merged = a + t.balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaxPerWalletModule.MaxWalletExceeded.selector, bob, merged, CAP));
        t.transfer(bob, a);
        // sending to the creator (under the cap: not exempt by default) and selling are never limited
        vm.prank(alice);
        t.transfer(creator, a / 2);
        _routerSell(alice, t, a / 2);
        // after the window, no limit
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(bob);
        router.buy{value: 500 ether}(address(t), 500 ether, 0, address(0), block.timestamp, "");
        assertGt(t.balanceOf(bob), CAP);
    }

    /// L-1: the creator is capped like everyone unless the launch sets exemptCreator.
    function test_creatorCappedUnlessExempt() public {
        HookTokenV2 t = _launchMpw(0);
        uint256 big = uint256(pad.getLaunch(address(t)).target) / 4;
        vm.deal(creator, big * 4);
        vm.prank(creator);
        vm.expectRevert();
        pad.buy{value: big}(address(t), 0);

        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        (ids[0], cfgs[0]) = (mpwId, _mpwCfg(500, 0, true));
        HookTokenV2 t2 = _launch(ids, cfgs, 0);
        vm.prank(creator);
        pad.buy{value: big}(address(t2), 0);
        assertGt(t2.balanceOf(creator), CAP);
        vm.prank(alice);
        vm.expectRevert(); // everyone else still capped
        pad.buy{value: big}(address(t2), 0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        mpw.validateConfig(_mpwCfg(9, 0));
        vm.expectRevert();
        mpw.validateConfig(_mpwCfg(5_001, 0));
        mpw.validateConfig(_mpwCfg(100, 0));
    }
}
