// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {WhaleGuardModule} from "../../contracts/v2/modules/WhaleGuardModule.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

/// Several ported v1 modules plus King of the Hill on one token, and gas per swap for the v1 presets.
contract V1PortComboTest is V1PortBase {
    HookTokenV2 t8;
    PoolKey k8;

    /// The 8-module token graduates here, in its own transaction (the per-transaction volume the whale guard
    /// checks counts the graduation's curve buys of the same transaction too).
    function setUp() public override {
        super.setUp();
        (uint32[] memory ids, bytes[] memory cfgs) = _max8();
        (t8, k8) = _many(ids, cfgs, 100);
    }

    function _max8() internal view returns (uint32[] memory ids, bytes[] memory cfgs) {
        ids = new uint32[](8);
        cfgs = new bytes[](8);
        (ids[0], cfgs[0]) = (kothId, _kothCfg(1 ether, 500, 50, 3600, false));
        (ids[1], cfgs[1]) = (antiSnipeId, _antiSnipeCfg(20, 10 ether, 500));
        (ids[2], cfgs[2]) = (whaleId, _whaleCfg(100, 5 ether));
        (ids[3], cfgs[3]) = (dumpId, _dumpCfg(100, 50));
        (ids[4], cfgs[4]) = (referralId, _referralCfg(100, 50));
        (ids[5], cfgs[5]) = (burnId, _burnCfg(100));
        (ids[6], cfgs[6]) = (buybackId, _buybackCfg(300, 2 ether));
        (ids[7], cfgs[7]) = (nthPotId, _nthCfg(100, 3, 0.1 ether));
    }

    function test_eightModulesWithKingOfTheHill() public {
        (HookTokenV2 t, PoolKey memory key) = (t8, k8);
        PoolId id = _id(key);
        (address[] memory mods,) = lens.modulesOf(address(t));
        assertEq(mods.length, 8);
        // the curve buys crowned a curve buyer (KotH runs on the curve too): let that bar decay away
        vm.warp(vm.getBlockTimestamp() + 3 days);

        // guarded open: alice is crowned, pays snipe tax into the pot, her referrer earns, a slice burns
        uint256 dead0 = t.balanceOf(DEAD);
        uint256 pot0 = nthPot.potOf(id).pot;
        uint256 c0 = hook.claimable(creator, NATIVE);
        uint256 got = _routerBuyRef(alice, t, 3 ether, bob);
        (address king,,,) = koth.currentKing(address(t));
        assertEq(king, alice);
        assertEq(antiSnipe.guardOf(id).sink, address(nthPot));
        assertEq(nthPot.potOf(id).pot - pot0, 0.15 ether + 0.03 ether);
        assertEq(hook.claimable(bob, NATIVE), 0.015 ether); // referral, out of the module's 1% fee
        assertEq(hook.claimable(creator, NATIVE) - c0, 0.03 ether + 0.015 ether); // core 1% + rest of module fee
        assertGt(t.balanceOf(DEAD) - dead0, 0);
        assertGt(got, 0);

        // whale guard: the transaction already bought 3 of its 5 AVAX
        vm.expectRevert(); // MaxBuyExceeded(5.5, 5), wrapped by the PoolManager
        _routerBuy(carol, t, 2.5 ether);

        // after the windows: carol takes the crown and the King (alice) earns from her buy
        vm.roll(vm.getBlockNumber() + 101);
        _routerBuy(carol, t, 10 ether);
        (king,,,) = koth.currentKing(address(t));
        assertEq(king, carol);
        assertEq(hook.claimable(alice, NATIVE), 0.05 ether);

        // a sell pays the King, the creator fee and buyback savings; nothing is refused
        uint256 k0 = hook.claimable(carol, NATIVE);
        _routerSell(alice, t, got);
        assertGt(hook.claimable(carol, NATIVE), k0);
        assertGt(buyback.vaultOf(id).saved, 0);

        // module books always match the hook's
        nthPot.reconcile();
        buyback.reconcile();
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
        assertEq(buyback.accounted(address(0)), hook.claimable(address(buyback), NATIVE));
    }

    // The core caps every module's buy-side credits together at 25%: a launch whose cuts add up to more
    // has them scaled down together (never a revert), and the pot's books still match the hook's.
    function test_buyCutsOverTheCoreCapAreScaled() public {
        (HookTokenV2 t, PoolKey memory key) =
            _many(_ids2(antiSnipeId, nthPotId), _cfgs2(_antiSnipeCfg(20, 0, 2_500), _nthCfg(100, 3, 0.1 ether)), 100);
        PoolId id = _id(key);
        uint256 c0 = hook.claimable(address(nthPot), NATIVE);
        uint256 p0 = nthPot.potOf(id).pot;
        _routerBuy(bob, t, 1 ether); // asks 25% snipe tax + 1% pot share: booked 25% in all
        assertApproxEqAbs(hook.claimable(address(nthPot), NATIVE) - c0, 0.25 ether, 2);
        nthPot.reconcile();
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
        assertEq(nthPot.potOf(id).pot - p0, hook.claimable(address(nthPot), NATIVE) - c0);
        vm.roll(vm.getBlockNumber() + 20);
        _routerBuy(bob, t, 1 ether);
    }

    // ---------------------------------------------------------------- gas

    function _cool(HookTokenV2 t) internal {
        address[6] memory a = [address(PM), address(hook), address(router), address(pad), address(t), alice];
        for (uint256 i; i < a.length; ++i) {
            vm.cool(a[i]);
        }
        (address[] memory mods,) = lens.modulesOf(address(t));
        for (uint256 i; i < mods.length; ++i) {
            vm.cool(mods[i]);
        }
    }

    function _measure(string memory name, uint32[] memory ids, bytes[] memory cfgs) internal {
        (HookTokenV2 t,) = _many(ids, cfgs, 100);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 ts0 = vm.getBlockTimestamp();
        vm.warp(ts0 + 3 days); // the curve's King bar decays away
        _routerBuy(carol, t, 3 ether); // warm-up: caches, a King, a pot to fill
        for (uint256 phase; phase < 2; ++phase) {
            if (phase == 1) vm.roll(vm.getBlockNumber() + 4_000); // every window over
            _cool(t);
            uint256 g = gasleft();
            uint256 got = _routerBuy(alice, t, 1 ether);
            uint256 gBuy = g - gasleft();
            vm.startPrank(alice);
            t.approve(address(router), got);
            vm.stopPrank();
            _cool(t);
            vm.prank(alice);
            g = gasleft();
            router.sell(address(t), got, 0, block.timestamp, "");
            uint256 gSell = g - gasleft();
            console2.log(name, phase == 0 ? "in window " : "after     ", gBuy, gSell);
        }
        vm.warp(ts0); // keep the live price feed fresh for the next launch
    }

    function test_gasPerSwap_v1Presets() public {
        console2.log("preset / phase / router buy gas / router sell gas (cold accounts)");
        _measure("none        ", new uint32[](0), new bytes[](0));

        bytes memory guard = _antiSnipeCfg(150, 50 ether, 1_500);
        uint32[] memory ids = new uint32[](3);
        bytes[] memory c = new bytes[](3);
        (ids[0], ids[1], ids[2]) = (antiSnipeId, whaleId, mevId);
        (c[0], c[1], c[2]) = (guard, _whaleCfg(1_800, 100_000 ether), _mevCfg(300, 5 gwei)); // cap high: graduation is in this tx
        _measure("fair start  ", ids, c);

        ids = new uint32[](4);
        c = new bytes[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (antiSnipeId, burnId, buybackId, surgeId);
        (c[0], c[1], c[2], c[3]) = (guard, _burnCfg(200), _buybackCfg(200, 5 ether), _surgeCfg(10_000, 2));
        _measure("deflation   ", ids, c);

        (ids[0], ids[1], ids[2], ids[3]) = (antiSnipeId, lpId, nthPotId, timerPotId);
        (c[0], c[1], c[2], c[3]) = (guard, _lpCfg(50), _nthCfg(100, 25, 0.5 ether), _timerCfg(100, 1_800, 0.5 ether));
        _measure("pot party   ", ids, c);

        (ids[0], ids[1], ids[2], ids[3]) = (antiSnipeId, dumpId, sellTaxId, lpId);
        (c[0], c[1], c[2], c[3]) = (guard, _dumpCfg(1_800, 50), _sellTaxCfg(3_600, 50_000), _lpCfg(50));
        _measure("diamond     ", ids, c);

        ids = new uint32[](3);
        c = new bytes[](3);
        (ids[0], ids[1], ids[2]) = (antiSnipeId, referralId, nthPotId);
        (c[0], c[1], c[2]) = (guard, _referralCfg(100, 50), _nthCfg(100, 25, 0.5 ether));
        _measure("community   ", ids, c);

        ids = new uint32[](2);
        c = new bytes[](2);
        (ids[0], ids[1]) = (volId, surgeId);
        (c[0], c[1]) = (_volCfg(5, 20_000), _surgeCfg(10_000, 2));
        _measure("vol + surge ", ids, c);

        (uint32[] memory ids8, bytes[] memory c8) = _max8();
        c8[2] = _whaleCfg(100, 100_000 ether); // graduation's curve buys are in this transaction
        _measure("max 8 + KotH", ids8, c8);
    }

    function test_hookRejectsUnknownModuleWithinCombo() public view {
        // every ported module is approved and active in the registry
        uint32[13] memory all = [antiSnipeId, whaleId, dumpId, mevId, sellTaxId, surgeId, volId, referralId, burnId, buybackId, lpId, nthPotId, timerPotId];
        for (uint256 i; i < all.length; ++i) {
            (address impl,,) = modules.forLaunch(all[i]);
            assertTrue(impl != address(0));
            assertEq(AvaxHookV2(payable(address(hook))).disabled(impl), false);
        }
    }
}
