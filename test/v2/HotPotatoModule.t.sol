// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HotPotatoModule} from "../../contracts/v2/modules/HotPotatoModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract HotPotatoModuleTest is NewModulesBase {
    HotPotatoModule hp;
    uint32 hpId;
    HookTokenV2 t;
    PoolKey key;

    uint256 constant BIG = 20 ether; // ~0.4% of supply at the graduation price (min: 0.1%)
    uint256 constant DUST = 0.05 ether;

    event PotatoPassed(address indexed token, address indexed from, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();
        hp = new HotPotatoModule(address(hook));
        hpId = modules.addModule(address(hp), '{"name":"Hot potato"}');
        (t, key) = _launchOne(hpId, _cfg(10, 7 days, false));
    }

    function _cfg(uint16 minBps, uint32 cool, bool refuse) internal pure returns (bytes memory) {
        return abi.encode(HotPotatoModule.Config(minBps, cool, refuse));
    }

    function _holderNow() internal view returns (address h) {
        (h,,) = hp.potato(address(t));
    }

    function test_capabilities() public view {
        assertEq(hp.capabilities(), ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.BLOCKS_SELLS);
        assertEq(hp.conflictGroups(), ModuleCaps.GROUP_SELL_LOCK);
        assertTrue(t.transferRules());
    }

    function test_potatoPassesBetweenBuyers() public {
        uint256 a = _routerBuy(alice, t, BIG);
        assertGe(a, hp.minBuy(address(t)));
        assertEq(_holderNow(), alice);

        // alice can't sell or send, by any route
        bytes memory err = _sellError(alice, t, a / 2);
        assertTrue(_has(err, HotPotatoModule.PotatoHeld.selector));
        (,, uint256 freeAt) = hp.potato(address(t));
        assertEq(freeAt, block.timestamp + 7 days); // H-2: always a cool-off, never a permanent lock
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HotPotatoModule.PotatoHeld.selector, alice, freeAt));
        t.transfer(bob, 1);
        vm.prank(alice);
        t.approve(address(agg), a);
        vm.expectRevert();
        agg.sellFrom(key, address(t), alice, a / 2);
        // a zero-value move by anyone is harmless and allowed
        vm.prank(bob);
        t.transferFrom(alice, bob, 0);
        // receiving is fine
        vm.prank(_holder(0));
        t.transfer(alice, 1 ether);

        // a small buy by someone else doesn't free her
        _routerBuy(bob, t, DUST);
        assertEq(_holderNow(), alice);
        // her own new buy keeps it with her
        _routerBuy(alice, t, BIG);
        assertEq(_holderNow(), alice);

        // a qualifying buy by bob passes it
        vm.expectEmit(true, true, true, false, address(hp));
        emit PotatoPassed(address(t), alice, bob, 0);
        uint256 b = _routerBuy(bob, t, BIG);
        assertEq(_holderNow(), bob);
        _routerSell(alice, t, a);
        vm.prank(alice);
        t.transfer(carol, 1 ether);
        _sellReverts(bob, t, b);
    }

    function test_othersTradeFreelyWhileHeld() public {
        _routerBuy(alice, t, BIG);
        address h = _holder(1);
        uint256 bal = t.balanceOf(h);
        _routerSell(h, t, bal / 2);
        vm.prank(h);
        t.transfer(carol, bal / 4);
    }

    function test_aggregatorBuysIgnoredByDefault() public {
        _routerBuy(alice, t, BIG);
        agg.swap(key, true, -int256(BIG)); // buyer unknown: neither takes nor frees the potato
        assertEq(_holderNow(), alice);
        // the holder can't escape by buying through an aggregator either (it's another address anyway)
        // and the aggregator itself can pass its tokens on
        vm.prank(address(agg));
        t.transfer(carol, 1 ether);
    }

    function test_refuseUnknownBuyers() public {
        (HookTokenV2 t2, PoolKey memory k2) = _launchOne(hpId, _cfg(10, 7 days, true));
        vm.expectRevert();
        agg.swap(k2, true, -int256(BIG));
        _routerBuy(alice, t2, BIG);
        (address h,,) = hp.potato(address(t2));
        assertEq(h, alice);
    }

    function test_coolOffFreesHolder() public {
        (HookTokenV2 t2,) = _launchOne(hpId, _cfg(10, 3600, false));
        uint256 a = _routerBuy(alice, t2, BIG);
        (address h, uint256 since, uint256 freeAt) = hp.potato(address(t2));
        assertEq(h, alice);
        assertEq(freeAt, since + 3600);
        assertFalse(hp.canSell(address(t2), alice));
        vm.warp(vm.getBlockTimestamp() + 3599);
        _sellReverts(alice, t2, a);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(hp.canSell(address(t2), alice));
        (h,,) = hp.potato(address(t2));
        assertEq(h, address(0));
        _routerSell(alice, t2, a);
    }

    function test_creatorNotExempt() public {
        uint256 c = _routerBuy(creator, t, BIG);
        assertEq(_holderNow(), creator);
        _sellReverts(creator, t, c);
    }

    /// On the curve the buyer is always known: curve buys pass the potato, and the holder can't sell back.
    function test_curvePhase() public {
        HookTokenV2 t2 = _launch(_one(hpId), _oneCfg(_cfg(10, 7 days, true)), 0);
        vm.prank(alice);
        pad.buy{value: 20 ether}(address(t2), 0);
        (address h,,) = hp.potato(address(t2));
        assertEq(h, alice);
        uint256 bal = t2.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HotPotatoModule.PotatoHeld.selector, alice, block.timestamp + 7 days));
        pad.sell(address(t2), bal / 2, 0);
        vm.prank(bob);
        pad.buy{value: 0.01 ether}(address(t2), 0); // too small to pass it
        (h,,) = hp.potato(address(t2));
        assertEq(h, alice);
        vm.prank(bob);
        pad.buy{value: 20 ether}(address(t2), 0);
        (h,,) = hp.potato(address(t2));
        assertEq(h, bob);
        vm.prank(alice);
        pad.sell(address(t2), bal / 2, 0);
        // the last curve buyer still holds it when the pool opens
        PoolKey memory k2 = _graduateN(t2, 40, 0);
        (h,,) = hp.potato(address(t2));
        assertTrue(h != address(0) && h != bob);
        assertTrue(hook.isOpen(_id(k2)));
    }

    function test_configBounds() public {
        vm.expectRevert();
        hp.validateConfig(_cfg(0, 0, false));
        vm.expectRevert();
        hp.validateConfig(_cfg(1001, 0, false));
        // H-2: the cool-off is mandatory, 1 hour .. 7 days (0 = "never" would lock the last holder for good)
        vm.expectRevert();
        hp.validateConfig(_cfg(10, 0, false));
        vm.expectRevert();
        hp.validateConfig(_cfg(10, 1 hours - 1, false));
        vm.expectRevert();
        hp.validateConfig(_cfg(10, 7 days + 1, false));
        hp.validateConfig(_cfg(1, 1 hours, true));
        hp.validateConfig(_cfg(1000, 7 days, false));
    }

    function test_onlyHook() public {
        IHookModule.SwapContext memory ctx;
        vm.expectRevert();
        hp.onAfterSwap(ctx);
        vm.expectRevert();
        hp.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }
}
