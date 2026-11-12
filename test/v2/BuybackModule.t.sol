// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BuybackModule} from "../../contracts/v2/modules/BuybackModule.sol";
import {ProbeModule} from "./V2Mocks.sol";
import {V1PortBase, Sandwicher} from "./V1PortBase.t.sol";

contract BuybackModuleTest is V1PortBase {
    using StateLibrary for IPoolManager;

    uint256 constant AGE = 30;

    /// Fills the buyback budget with router round trips, then lets the reference price age (v1 _fillBuyback).
    function _fill(HookTokenV2 t, uint256 rounds) internal {
        vm.startPrank(alice);
        t.approve(address(router), type(uint256).max);
        uint256 got = router.buy{value: 100 ether}(address(t), 100 ether, 0, address(0), block.timestamp, "");
        for (uint256 i; i < rounds; ++i) {
            uint256 out = router.sell(address(t), got, 0, block.timestamp, "");
            got = router.buy{value: out}(address(t), out, 0, address(0), block.timestamp, "");
        }
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 2 * AGE + 1);
        _routerBuy(alice, t, 0.01 ether); // checkpoint
        vm.roll(vm.getBlockNumber() + AGE);
    }

    // v1 test_buybackAndBurn
    function test_buybackAndBurn() public {
        (HookTokenV2 t, PoolKey memory key) = _one(buybackId, _buybackCfg(500, 1 ether));
        PoolId id = _id(key);
        uint256 got = _routerBuy(bob, t, 20 ether);
        _routerSell(bob, t, got);
        uint256 saved = buyback.vaultOf(id).saved;
        assertGt(saved, 0.1 ether);
        assertEq(hook.claimable(address(buyback), NATIVE), saved);
        vm.prank(keeperBot);
        vm.expectRevert(BuybackModule.BuybackNotReady.selector);
        buyback.executeBuyback(key); // no reference price old enough yet
        vm.roll(vm.getBlockNumber() + AGE);
        uint256 dead0 = t.balanceOf(DEAD);
        vm.prank(keeperBot);
        (uint256 spent, uint256 burned) = buyback.executeBuyback(key);
        assertGt(spent, 0);
        assertLe(spent, 1 ether);
        assertEq(t.balanceOf(DEAD) - dead0, burned);
        assertEq(buyback.vaultOf(id).saved, saved - spent);
        assertEq(hook.claimable(address(buyback), NATIVE), saved - spent);
        assertEq(buyback.accounted(address(0)), saved - spent);
        vm.prank(keeperBot);
        vm.expectRevert(BuybackModule.BuybackNotReady.selector);
        buyback.executeBuyback(key); // cooldown
    }

    // M-1: only the keeper (or the owner) can run a buyback, and only the owner sets the keeper.
    function test_M1_keeperOnly() public {
        (HookTokenV2 t, PoolKey memory key) = _one(buybackId, _buybackCfg(500, 10 ether));
        _fill(t, 6);
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotKeeper.selector);
        buyback.executeBuyback(key);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        buyback.setKeeper(alice);
        vm.prank(keeperBot);
        (uint256 spent, uint256 burned) = buyback.executeBuyback(key);
        assertGt(spent, 0);
        assertGt(burned, 0);
        // ownership goes to the Safe in two steps
        buyback.transferOwnership(SAFE);
        vm.prank(SAFE);
        buyback.acceptOwnership();
        assertEq(buyback.owner(), SAFE);
    }

    // HK-2 PoC re-run: a pump right before a buyback can't be sold into it.
    function test_HK2_buybackRefusedAfterPump() public {
        (HookTokenV2 t, PoolKey memory key) = _one(buybackId, _buybackCfg(500, 1 ether));
        uint256 got = _routerBuy(alice, t, 40 ether);
        _routerSell(alice, t, got / 2);
        vm.roll(vm.getBlockNumber() + 2 * AGE + 1);
        _routerBuy(alice, t, 1 wei); // checkpoints the price
        vm.roll(vm.getBlockNumber() + AGE);
        _routerBuy(alice, t, 300 ether); // the attacker's front-run
        vm.prank(alice);
        vm.expectRevert(BuybackModule.NotKeeper.selector);
        buyback.executeBuyback(key);
        vm.prank(keeperBot);
        vm.expectRevert(BuybackModule.BuybackNotReady.selector);
        buyback.executeBuyback(key); // spot is past 5% above the aged reference: nothing to buy
    }

    // M-1 PoC re-run: pump in block N, buyback in N+1, dump. A pump past the reference bound gets no
    // buyback; what is left for a tiny pump is sandwich dust, under 1% of the buyback.
    function test_M1_crossBlockSandwichUnprofitable() public {
        (HookTokenV2 t, PoolKey memory key) = _one(buybackId, _buybackCfg(500, 10 ether));
        _fill(t, 6);
        PoolId id = _id(key);
        assertGt(buyback.vaultOf(id).saved, 3 ether);
        Sandwicher j = new Sandwicher(PM);
        vm.deal(address(j), 2_000 ether);
        for (uint256 a = 0.5 ether; a <= 512 ether; a *= 2) {
            uint256 snap = vm.snapshotState();
            uint256 a0 = address(j).balance;
            uint256 ref = buyback.buybackReference(id);
            j.swap(key, true, a); // block N: pump (a buy lowers sqrtPrice: AVAX is currency0)
            (uint160 pumped,,,) = PM.getSlot0(id);
            vm.roll(vm.getBlockNumber() + 1);
            uint256 spent;
            vm.prank(keeperBot);
            try buyback.executeBuyback(key) returns (uint256 s, uint256) {
                spent = s;
            } catch {}
            j.swap(key, false, t.balanceOf(address(j))); // dump into it
            int256 profit = int256(address(j).balance) - int256(a0);
            console2.log("pump / buyback spent", a, spent);
            console2.logInt(profit);
            // pumped past the 5% bound from the aged reference: the buyback buys nothing
            if (uint256(pumped) <= (ref * 9_747) / 10_000) assertEq(spent, 0);
            if (profit > 0) assertLt(uint256(profit), spent / 100);
            vm.revertToState(snap);
        }
    }

    // L-1: a dust swap earlier in the same block doesn't block the buyback.
    function test_L1_dustSwapCantBlockBuyback() public {
        (HookTokenV2 t, PoolKey memory key) = _one(buybackId, _buybackCfg(500, 10 ether));
        _fill(t, 6);
        _routerBuy(bob, t, 1);
        vm.prank(keeperBot);
        (uint256 spent,) = buyback.executeBuyback(key);
        assertGt(spent, 0);
    }

    // Readiness: at least a tenth of the per-run cap saved.
    function test_dustSavingsNotReady() public {
        (HookTokenV2 t, PoolKey memory key) = _one(buybackId, _buybackCfg(100, 100 ether));
        uint256 got = _routerBuy(bob, t, 20 ether);
        _routerSell(bob, t, got);
        vm.roll(vm.getBlockNumber() + AGE);
        vm.prank(keeperBot);
        vm.expectRevert(BuybackModule.BuybackNotReady.selector);
        buyback.executeBuyback(key);
    }

    // Savings ride the (isolated) sell path: if the hook drops them over the module cut cap, they are
    // never counted, so this pool can't spend another pool's savings.
    function test_scaledSellCreditIsCountedAtTheBookedAmount() public {
        ProbeModule p = new ProbeModule(address(hook), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP, 0);
        uint32 pid = modules.addModule(address(p), '{"name":"greedy"}');
        (HookTokenV2 t, PoolKey memory key) = _many(_ids2(pid, buybackId), _cfgs2("", _buybackCfg(500, 1 ether)), 100);
        (HookTokenV2 t2, PoolKey memory key2) = _one(buybackId, _buybackCfg(500, 1 ether));
        uint256 got2 = _routerBuy(bob, t2, 10 ether);
        _routerSell(bob, t2, got2); // pool 2 saves for real
        uint256 saved2 = buyback.vaultOf(_id(key2)).saved;
        assertGt(saved2, 0);

        uint256 got = _routerBuy(bob, t, 10 ether);
        p.set(false, 2_500, 0); // the greedy module takes the whole 25% cap of every side
        _routerSell(bob, t, got);
        uint256 announced = buyback.vaultOf(_id(key)).saved; // counted optimistically...
        assertGt(announced, 0);
        buyback.reconcile();
        // ...and cut to what the hook booked: 25% cap / (25% + 5%) asked = 5/6 of it
        uint256 booked = buyback.vaultOf(_id(key)).saved;
        assertApproxEqAbs(booked, (announced * 5) / 6, 2);
        assertEq(hook.claimable(address(buyback), NATIVE), booked + saved2);
        assertEq(buyback.vaultOf(_id(key2)).saved, saved2);
        assertEq(buyback.accounted(address(0)), hook.claimable(address(buyback), NATIVE));
    }

    function test_configBounds() public {
        vm.expectRevert();
        buyback.validateConfig(_buybackCfg(0, 1 ether));
        vm.expectRevert();
        buyback.validateConfig(_buybackCfg(1_001, 1 ether));
        vm.expectRevert();
        buyback.validateConfig(_buybackCfg(100, 0));
        buyback.validateConfig(_buybackCfg(1_000, 1));
        assertEq(buyback.capabilities() & ModuleCaps.BLOCKS_SELLS, 0);
        // v1: creator fee + buyback <= 15% of a sell
        vm.expectRevert();
        this.launchExt(_ids1(buybackId), _cfgs1(_buybackCfg(1_000, 1 ether)), 600);
        this.launchExt(_ids1(buybackId), _cfgs1(_buybackCfg(1_000, 1 ether)), 500);
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs, uint16 fee) external returns (HookTokenV2) {
        return _launch(ids, cfgs, fee);
    }
}
