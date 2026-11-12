// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {V1PortBase, SpoofSwapper} from "./V1PortBase.t.sol";

contract NthBuyPotModuleTest is V1PortBase {
    using StateLibrary for IPoolManager;

    // v1 test_graduationIntoUniswapV4 (pot part): every 3rd qualifying buy takes the pot, then claims it.
    // The graduation's curve buys (one block) already counted once and filled the pot.
    function test_everyNthQualifyingBuyWins() public {
        (HookTokenV2 t, PoolKey memory key) = _one(nthPotId, _nthCfg(100, 3, 0.1 ether));
        PoolId id = _id(key);
        assertEq(nthPot.potOf(id).buyCount, 1);
        uint256 pot0 = nthPot.potOf(id).pot;
        assertGt(pot0, 0);
        uint256 b = vm.getBlockNumber();
        for (uint256 i; i < 2; ++i) {
            vm.roll(b + 1 + i);
            assertEq(nthPot.buysUntilPot(id), 2 - i);
            _routerBuy(bob, t, 1 ether);
        }
        uint256 won = pot0 + 0.02 ether; // the pot plus the winning buy's own share
        assertEq(hook.claimable(bob, NATIVE), won);
        assertEq(nthPot.potOf(id).pot, 0);
        assertEq(nthPot.potOf(id).totalPaid, won);
        uint256 bal = bob.balance;
        vm.prank(bob);
        hook.claim(NATIVE, bob);
        assertEq(bob.balance - bal, won);
    }

    function test_oneSlotPerBlockAndMinBuy() public {
        (HookTokenV2 t, PoolKey memory key) = _one(nthPotId, _nthCfg(100, 3, 0.5 ether));
        PoolId id = _id(key);
        uint256 pot0 = nthPot.potOf(id).pot; // the curve buys: one block, counted once
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(bob, t, 1 ether);
        _routerBuy(carol, t, 1 ether); // same block: doesn't count
        assertEq(nthPot.potOf(id).buyCount, 2);
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(carol, t, 0.4 ether); // below the minimum: funds the pot, doesn't count
        assertEq(nthPot.potOf(id).buyCount, 2);
        assertEq(nthPot.potOf(id).pot - pot0, 0.024 ether);
        _routerBuy(carol, t, 0.5 ether); // wins: the pot + 0.005
        assertEq(hook.claimable(carol, NATIVE), pot0 + 0.029 ether);
    }

    // HK-3 PoC re-run: router-shaped hookData from anyone but the router names nobody, so a spoofer can't
    // count buys for (or win the pot as) someone else; aggregator buys fund the pot but never count.
    function test_HK3_spoofedBuyerCantWinPot() public {
        (, PoolKey memory key) = _one(nthPotId, _nthCfg(500, 2, 0.1 ether));
        uint256 pot0 = nthPot.potOf(_id(key)).pot;
        SpoofSwapper s = new SpoofSwapper(PM);
        vm.deal(address(s), 100 ether);
        for (uint256 i; i < 4; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            s.buyAs(key, 1 ether, alice, address(0));
            _directBuy(key, 1 ether);
        }
        assertEq(hook.claimable(alice, NATIVE), 0);
        assertEq(nthPot.potOf(_id(key)).buyCount, 1); // only the curve buys' block
        assertEq(nthPot.potOf(_id(key)).pot - pot0, 0.4 ether);
    }

    // HK-3: a price-limited partial buy is refused by the core, so nobody qualifies on a partial fill.
    function test_HK3_partialFillRefused() public {
        (, PoolKey memory key) = _one(nthPotId, _nthCfg(500, 2, 0.1 ether));
        (uint160 sp,,,) = PM.getSlot0(_id(key));
        vm.expectRevert();
        agg.swapWithLimit(key, true, -int256(1 ether), sp - sp / 100);
    }

    // The module is shared: each pool's pot is its own share of the module's claim.
    function test_poolsKeepSeparatePots() public {
        (HookTokenV2 a, PoolKey memory ka) = _one(nthPotId, _nthCfg(100, 3, 0.1 ether));
        (HookTokenV2 b, PoolKey memory kb) = _one(nthPotId, _nthCfg(200, 5, 0.1 ether));
        uint256 a0 = nthPot.potOf(_id(ka)).pot;
        uint256 b0 = nthPot.potOf(_id(kb)).pot;
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(bob, a, 10 ether);
        _routerBuy(bob, b, 10 ether);
        assertEq(nthPot.potOf(_id(ka)).pot - a0, 0.1 ether);
        assertEq(nthPot.potOf(_id(kb)).pot - b0, 0.2 ether);
        assertEq(hook.claimable(address(nthPot), NATIVE), a0 + b0 + 0.3 ether);
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(carol, a, 1 ether); // the 3rd counted buy: wins pool a's pot only
        assertEq(hook.claimable(carol, NATIVE), a0 + 0.11 ether);
        assertEq(hook.claimable(address(nthPot), NATIVE), b0 + 0.2 ether);
        assertEq(nthPot.accounted(address(0)), b0 + 0.2 ether);
    }

    function test_configBounds() public {
        vm.expectRevert();
        nthPot.validateConfig(_nthCfg(0, 2, 1));
        vm.expectRevert();
        nthPot.validateConfig(_nthCfg(1_001, 2, 1));
        vm.expectRevert();
        nthPot.validateConfig(_nthCfg(100, 1, 1));
        vm.expectRevert();
        nthPot.validateConfig(_nthCfg(100, 100_001, 1));
        vm.expectRevert();
        nthPot.validateConfig(_nthCfg(100, 2, 0));
        nthPot.validateConfig(_nthCfg(1_000, 100_000, 1));
    }
}
