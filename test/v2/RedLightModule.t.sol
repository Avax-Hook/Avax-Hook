// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {RedLightModule} from "../../contracts/v2/modules/RedLightModule.sol";
import {EarlyBlocksBase} from "./EarlyBlocksBase.t.sol";

contract RedLightModuleTest is EarlyBlocksBase {
    RedLightModule rl;
    uint32 rlId;

    function setUp() public override {
        super.setUp();
        rl = new RedLightModule(address(hook));
        rlId = modules.addModule(address(rl), '{"name":"Red light"}');
    }

    function _cfg(uint32 slot, uint16 green, uint16 maxRed, bool sellsOpen) internal pure returns (bytes memory) {
        return abi.encode(RedLightModule.Config(slot, green, maxRed, sellsOpen));
    }

    /// Warps to the start of the next slot with colour `green`.
    function _warpTo(HookTokenV2 t, bool green) internal {
        uint256 k = rl.currentSlot(address(t));
        for (uint256 i = 1; i < 5_000; ++i) {
            (bool g, uint256 at) = rl.slotGreen(address(t), k + i);
            if (g == green) {
                vm.warp(at);
                assertEq(rl.isGreen(address(t)), green);
                return;
            }
        }
        revert("no such slot");
    }

    function _launchGraduated(bytes memory cfg) internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(_one(rlId), _oneCfg(cfg), 0);
        _warpTo(t, true);
        key = _graduateN(t, 10, 0); // one block, one timestamp: all green
    }

    function test_capabilities() public view {
        assertEq(rl.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS);
        assertEq(rl.conflictGroups(), ModuleCaps.GROUP_SCHEDULE);
    }

    function test_seedIsPublicAndFixed() public {
        uint256 blk = vm.getBlockNumber();
        HookTokenV2 t = _launch(_one(rlId), _oneCfg(_cfg(60, 5_000, 10, false)), 0);
        PoolId id = rl.poolOf(address(t));
        assertEq(rl.seedOf(address(t)), keccak256(abi.encode(blockhash(blk - 1), id)));
        // slot k's draw is keccak(seed, k) mod 1e4 < greenBps (unless forced green)
        bytes32 seed = rl.seedOf(address(t));
        for (uint256 k = 1; k < 50; ++k) {
            (bool g,) = rl.slotGreen(address(t), k);
            bool raw = uint256(keccak256(abi.encode(seed, k))) % 10_000 < 5_000;
            if (raw) assertTrue(g);
        }
    }

    function test_launchSlotGreen_devBuyPasses() public {
        HookTokenV2 t = _launchWithDevBuy(_one(rlId), _oneCfg(_cfg(60, 1_000, 30, false)), 1 ether);
        assertGt(t.balanceOf(creator), 0);
        assertTrue(rl.isGreen(address(t)));
        (bool g, uint256 at) = rl.slotGreen(address(t), 0);
        assertTrue(g);
        assertEq(at, vm.getBlockTimestamp());
    }

    function test_curveRedRefusesBuysAndSells() public {
        HookTokenV2 t = _launch(_one(rlId), _oneCfg(_cfg(60, 5_000, 10, false)), 0);
        _curveBuy(alice, t, 2 ether); // slot 0
        _warpTo(t, false);
        uint256 greenAt = rl.nextChange(address(t));
        assertGt(greenAt, vm.getBlockTimestamp());
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RedLightModule.RedLight.selector, greenAt));
        pad.buy{value: 1 ether}(address(t), 0);
        uint256 bal = t.balanceOf(alice);
        vm.startPrank(alice);
        t.approve(address(pad), bal);
        vm.expectRevert();
        pad.sell(address(t), bal / 2, 0);
        vm.stopPrank();
        vm.warp(greenAt);
        assertTrue(rl.isGreen(address(t)));
        _curveBuy(bob, t, 1 ether);
        _curveSell(alice, t, bal / 4);
    }

    function test_poolRedAllRoutes() public {
        (HookTokenV2 t, PoolKey memory key) = _launchGraduated(_cfg(30, 5_000, 10, false));
        _routerBuy(alice, t, 1 ether);
        _warpTo(t, false);
        bytes memory err = _buyError(bob, t, 1 ether);
        assertTrue(_has(err, RedLightModule.RedLight.selector));
        err = _sellError(alice, t, t.balanceOf(alice));
        assertTrue(_has(err, RedLightModule.RedLight.selector));
        vm.expectRevert();
        agg.swap(key, true, -int256(1 ether));
        _warpTo(t, true);
        _routerBuy(bob, t, 1 ether);
        _routerSell(alice, t, t.balanceOf(alice));
        agg.swap(key, true, -int256(1 ether));
    }

    function test_sellsOpenVariant() public {
        (HookTokenV2 t,) = _launchGraduated(_cfg(30, 5_000, 10, true));
        _routerBuy(alice, t, 1 ether);
        _warpTo(t, false);
        _buyReverts(bob, t, 1 ether);
        _routerSell(alice, t, t.balanceOf(alice)); // red closes buys only
    }

    /// The forced green: never more than maxRedSlots red slots in a row, even at 10% green.
    function test_redRunsBounded() public {
        HookTokenV2 t = _launch(_one(rlId), _oneCfg(_cfg(60, 1_000, 3, false)), 0);
        uint256 run;
        uint256 longest;
        uint256 greens;
        for (uint256 k; k < 1_500; ++k) {
            (bool g,) = rl.slotGreen(address(t), k);
            if (g) {
                run = 0;
                ++greens;
            } else if (++run > longest) {
                longest = run;
            }
        }
        assertEq(longest, 3); // the bound is reached at 10% green, never passed
        assertGt(greens, 1_500 / 4); // forced greens lift it well above 10%
    }

    /// nextChange is the start of the first slot of the other colour.
    function test_nextChange() public {
        HookTokenV2 t = _launch(_one(rlId), _oneCfg(_cfg(45, 4_000, 20, false)), 0);
        for (uint256 r; r < 6; ++r) {
            bool g = rl.isGreen(address(t));
            uint256 nc = rl.nextChange(address(t));
            assertGt(nc, vm.getBlockTimestamp());
            vm.warp(nc - 1);
            assertEq(rl.isGreen(address(t)), g);
            vm.warp(nc);
            assertEq(rl.isGreen(address(t)), !g);
        }
    }

    function testFuzz_runBound(uint16 green, uint8 maxRed, uint32 slot, uint256 k) public {
        uint16 gb = uint16(bound(green, 1_000, 9_500));
        uint32 s = uint32(bound(slot, 10, 3_600));
        uint16 m = uint16(bound(maxRed, 1, 60));
        if (uint256(m) * s > 3_600) m = uint16(3_600 / s);
        HookTokenV2 t = _launch(_one(rlId), _oneCfg(_cfg(s, gb, m, false)), 0);
        k = bound(k, 0, 1_000_000);
        bool any;
        for (uint256 j; j <= m; ++j) {
            (bool g,) = rl.slotGreen(address(t), k + j);
            if (g) any = true;
        }
        assertTrue(any); // every m + 1 consecutive slots hold a green one: closed <= 1 hour
    }

    function test_callbackGasWorstCase() public {
        HookTokenV2 t = _launch(_one(rlId), _oneCfg(_cfg(60, 1_000, 60, false)), 0);
        _warpTo(t, false);
        IHookModule.SwapContext memory c;
        c.poolId = rl.poolOf(address(t));
        c.isBuy = true;
        vm.prank(address(hook));
        uint256 g = gasleft();
        try rl.onBeforeSwap(c) {} catch {}
        g -= gasleft();
        emit log_named_uint("red-light refusing onBeforeSwap gas", g);
        assertLt(g, 100_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        rl.validateConfig(_cfg(9, 5_000, 10, false));
        vm.expectRevert();
        rl.validateConfig(_cfg(3_601, 5_000, 1, false));
        vm.expectRevert();
        rl.validateConfig(_cfg(60, 999, 10, false));
        vm.expectRevert();
        rl.validateConfig(_cfg(60, 9_501, 10, false));
        vm.expectRevert();
        rl.validateConfig(_cfg(60, 5_000, 0, false));
        vm.expectRevert();
        rl.validateConfig(_cfg(60, 5_000, 61, false));
        vm.expectRevert();
        rl.validateConfig(_cfg(120, 5_000, 31, false)); // 62 minutes closed
        rl.validateConfig(_cfg(60, 5_000, 60, true));
        rl.validateConfig(_cfg(3_600, 9_500, 1, false));
    }
}
