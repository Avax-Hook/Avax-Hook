// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AutoLpModule} from "../../contracts/v2/modules/AutoLpModule.sol";
import {V1PortBase, Sandwicher} from "./V1PortBase.t.sol";

contract AutoLpModuleTest is V1PortBase {
    using StateLibrary for IPoolManager;

    AutoLpModule autoLp;
    uint32 autoLpId;
    uint256 constant AGE = 30;

    function setUp() public override {
        super.setUp();
        autoLp = new AutoLpModule(address(hook));
        autoLpId = modules.addModule(address(autoLp), '{"name":"Auto-LP"}');
    }

    function _cfg(uint16 bps, uint96 maxSpend) internal pure returns (bytes memory) {
        return abi.encode(AutoLpModule.Config(bps, maxSpend));
    }

    /// The module's locked position in the pool.
    function _position(PoolKey memory key) internal view returns (uint128) {
        bytes32 pid = Position.calculatePositionKey(
            address(autoLp), TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bytes32(0)
        );
        return PM.getPositionLiquidity(_id(key), pid);
    }

    /// Router round trips to save funds, then lets the reference price age.
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

    function _ledgerHolds(address quote) internal view {
        assertEq(hook.claimable(address(autoLp), Currency.wrap(quote)), autoLp.accounted(quote), "ledger = hook books");
    }

    function test_savesBuysAndSells() public {
        (HookTokenV2 t, PoolKey memory key) = _one(autoLpId, _cfg(100, 1 ether));
        PoolId id = _id(key);
        uint256 s0 = autoLp.vaultOf(id).saved;
        _routerBuy(bob, t, 10 ether);
        uint256 s1 = autoLp.vaultOf(id).saved;
        assertEq(s1 - s0, 0.1 ether, "1% of the buy");
        vm.startPrank(bob);
        t.approve(address(router), type(uint256).max);
        router.sell(address(t), t.balanceOf(bob), 0, block.timestamp, "");
        vm.stopPrank();
        assertGt(autoLp.vaultOf(id).saved, s1, "sells save too");
        autoLp.reconcile();
        _ledgerHolds(address(0));
    }

    function test_curveSavingsCompoundAfterGraduation() public {
        HookTokenV2 t = _launch(_ids1(autoLpId), _cfgs1(_cfg(200, 1 ether)), 100);
        PoolKey memory key = _graduate(t); // the whole curve is bought with the module saving 2%
        PoolId id = _id(key);
        uint256 saved = autoLp.vaultOf(id).saved;
        assertGt(saved, 1 ether, "curve buys saved");
        vm.roll(vm.getBlockNumber() + 2 * AGE + 1);
        _routerBuy(alice, t, 0.01 ether); // checkpoint
        vm.roll(vm.getBlockNumber() + AGE);
        uint128 before = PM.getLiquidity(id);
        (uint256 q, uint256 tk) = autoLp.compound(key);
        assertGt(q, 0);
        assertGt(tk, 0);
        assertGt(PM.getLiquidity(id), before, "pool deepened");
        assertEq(_position(key), autoLp.vaultOf(id).liquidity, "position owned by the module");
        _ledgerHolds(address(0));
    }

    function test_compoundAddsLockedLiquidity() public {
        (HookTokenV2 t, PoolKey memory key) = _one(autoLpId, _cfg(300, 2 ether));
        _fill(t, 6);
        PoolId id = _id(key);
        uint256 saved = autoLp.vaultOf(id).saved;
        assertGt(saved, 0.2 ether);
        uint128 before = PM.getLiquidity(id);
        vm.prank(carol); // anyone
        (uint256 q, uint256 tk) = autoLp.compound(key);
        console2.log("compound quote / tokens", q, tk);
        AutoLpModule.Vault memory v = autoLp.vaultOf(id);
        assertLe(saved - v.saved, 2 ether, "at most maxSpend");
        assertGt(PM.getLiquidity(id), before);
        assertGt(_position(key), 0);
        // what wasn't paired stays with the module, small next to what went in
        assertLt(uint256(v.quoteHand), q / 10 + 1e6);
        assertEq(address(autoLp).balance, v.quoteHand, "hand = balance");
        assertEq(t.balanceOf(address(autoLp)), v.tokenHand, "hand = balance (token)");
        _ledgerHolds(address(0));
        vm.expectRevert(AutoLpModule.CompoundNotReady.selector);
        autoLp.compound(key); // cooldown
    }

    function test_secondCompoundReinvestsPositionFees() public {
        (HookTokenV2 t, PoolKey memory key) = _one(autoLpId, _cfg(300, 1 ether));
        _fill(t, 6);
        PoolId id = _id(key);
        autoLp.compound(key);
        uint128 l1 = autoLp.vaultOf(id).liquidity;
        _fill(t, 6); // more trades: more savings and fees on the module's position
        autoLp.compound(key);
        assertGt(autoLp.vaultOf(id).liquidity, l1);
        assertEq(_position(key), autoLp.vaultOf(id).liquidity);
        _ledgerHolds(address(0));
    }

    function test_refusedAfterPump() public {
        (HookTokenV2 t, PoolKey memory key) = _one(autoLpId, _cfg(300, 2 ether));
        _fill(t, 6);
        _routerBuy(alice, t, 300 ether); // front-run: spot leaves the 2% band around the aged reference
        vm.expectRevert(AutoLpModule.CompoundNotReady.selector);
        autoLp.compound(key);
    }

    /// Pump in block N, compound in N+1, dump: anything the attacker clears is dust next to the compound.
    function test_crossBlockSandwichUnprofitable() public {
        (HookTokenV2 t, PoolKey memory key) = _one(autoLpId, _cfg(300, 5 ether));
        _fill(t, 8);
        Sandwicher j = new Sandwicher(PM);
        vm.deal(address(j), 2_000 ether);
        for (uint256 a = 0.05 ether; a <= 64 ether; a *= 4) {
            uint256 snap = vm.snapshotState();
            uint256 a0 = address(j).balance;
            j.swap(key, true, a);
            vm.roll(vm.getBlockNumber() + 1);
            uint256 added;
            try autoLp.compound(key) returns (uint256 q, uint256) {
                added = q;
            } catch {}
            j.swap(key, false, t.balanceOf(address(j)));
            int256 profit = int256(address(j).balance) - int256(a0);
            console2.log("pump / compound quote", a, added);
            console2.logInt(profit);
            if (profit > 0) assertLt(uint256(profit), added / 50 + 1);
            vm.revertToState(snap);
        }
    }

    function test_noCompoundBeforeGraduationOrWithDust() public {
        HookTokenV2 t = _launch(_ids1(autoLpId), _cfgs1(_cfg(100, 1 ether)), 100);
        PoolKey memory key = pad.poolKey(address(t));
        vm.expectRevert(AutoLpModule.CompoundNotReady.selector);
        autoLp.compound(key); // curve phase
        (, PoolKey memory k2) = _one(autoLpId, _cfg(1, 100 ether));
        vm.roll(vm.getBlockNumber() + 3 * AGE);
        vm.expectRevert(AutoLpModule.CompoundNotReady.selector);
        autoLp.compound(k2); // savings under a tenth of maxSpend
    }

    /// Two pools share the module's AVAX claim: compounding one never spends the other's share.
    function test_poolsKeepTheirOwnShares() public {
        (HookTokenV2 a, PoolKey memory ka) = _one(autoLpId, _cfg(300, 2 ether));
        (HookTokenV2 b, PoolKey memory kb) = _one(autoLpId, _cfg(300, 2 ether));
        _routerBuy(bob, b, 20 ether);
        _fill(a, 6);
        uint256 bSaved = autoLp.vaultOf(_id(kb)).saved;
        autoLp.compound(ka);
        assertEq(autoLp.vaultOf(_id(kb)).saved, bSaved, "other pool untouched");
        _ledgerHolds(address(0));
        uint256 sumShares = autoLp.vaultOf(_id(ka)).saved + autoLp.vaultOf(_id(kb)).saved;
        assertEq(autoLp.accounted(address(0)), sumShares, "shares add up");
        b; // silence
    }

    function test_badConfig() public {
        vm.expectRevert();
        autoLp.validateConfig(_cfg(0, 1 ether));
        vm.expectRevert();
        autoLp.validateConfig(_cfg(501, 1 ether));
        vm.expectRevert();
        autoLp.validateConfig(_cfg(100, 0));
        autoLp.validateConfig(_cfg(500, 1));
    }
}
