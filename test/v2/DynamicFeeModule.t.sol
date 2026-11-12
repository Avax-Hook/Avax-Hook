// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {DynamicFeeModule} from "../../contracts/v2/modules/DynamicFeeModule.sol";
import {V1PortBase, MultiTrader} from "./V1PortBase.t.sol";

contract DynamicFeeModuleTest is V1PortBase {
    HookTokenV2 t;
    PoolKey key;
    HookTokenV2 p;
    HookTokenV2 a;
    HookTokenV2 b;
    HookTokenV2 c;

    /// Graduation in its own transaction: the surge is sized on the transaction's volume, which counts the
    /// curve buys of the same transaction too.
    function setUp() public override {
        super.setUp();
        (t, key) = _one(surgeId, _surgeCfg(30_000, 2));
        (p,) = _plain();
        (a,) = _one(surgeId, _surgeCfg(100_000, 10));
        (b,) = _one(surgeId, _surgeCfg(100_000, 10));
        (c,) = _one(surgeId, _surgeCfg(100_000, 10));
    }

    function test_bigTradesPayMoreSmallTradesPayBase() public {
        // a dust buy pays ~the base fee
        assertApproxEqRel(_routerBuy(bob, t, 0.001 ether), _routerBuy(bob, p, 0.001 ether), 0.0001e18);
        uint256 q = surge.quoteSurge(_id(key), address(t), address(0), true, 40 ether);
        assertGt(q, 0);
        assertLe(q, 27_000); // never above ceiling - base
        // a big buy pays the surge
        uint256 big = _routerBuy(carol, t, 40 ether);
        uint256 bigPlain = _routerBuy(carol, p, 40 ether);
        assertLt(big, bigPlain);
        // and so does a big sell
        assertLt(_routerSell(carol, t, big / 2), _routerSell(carol, p, big / 2));
    }

    // Sized on the transaction's volume (HK-4 style): the second half of a split buy pays the surge of the
    // whole 40, so splitting saves far less than sizing each swap alone would.
    function test_splittingDoesntDodgeTheSurge() public {
        uint256 single = _routerBuy(bob, a, 40 ether);
        MultiTrader m = new MultiTrader(address(router));
        vm.deal(address(m), 40 ether);
        m.buys(address(b), 20 ether, 2);
        uint256 split = b.balanceOf(address(m));
        // what a 20 + 20 split would get if each swap were sized alone: two fresh-pool halves
        uint256 half = _routerBuy(carol, c, 20 ether);
        assertGt(split, single); // the first half is cheaper...
        assertLt(split - single, (2 * half - single) / 2); // ...but most of the dodge is gone
    }

    function test_ceilingMustBeAboveBaseFee() public {
        vm.expectRevert(); // core base fee 0.3% = 3,000 pips
        this.launchExt(_ids1(surgeId), _cfgs1(_surgeCfg(3_000, 2)));
        this.launchExt(_ids1(surgeId), _cfgs1(_surgeCfg(3_001, 2)));
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs) external returns (HookTokenV2) {
        return _launch(ids, cfgs, 0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        surge.validateConfig(_surgeCfg(100_001, 2));
        vm.expectRevert();
        surge.validateConfig(_surgeCfg(10_000, 0));
        vm.expectRevert();
        surge.validateConfig(_surgeCfg(10_000, 11));
        surge.validateConfig(_surgeCfg(100_000, 10));
    }

    /// Audit fix: the surge is sized on the block's volume per side, so splitting a buy over separate
    /// transactions of one block doesn't dodge it either.
    function test_splittingAcrossTxsInOneBlockDoesntDodge() public {
        uint256 single = _routerBuy(bob, a, 40 ether);
        // the same 40 in two transactions of one block, on an identical fresh pool
        uint256 split = _routerBuy(carol, b, 20 ether) + _routerBuy(carol, b, 20 ether);
        uint256 half = _routerBuy(alice, c, 20 ether); // a 20 sized alone
        assertGt(split, single); // the first half is cheaper...
        assertLt(split - single, (2 * half - single) / 2); // ...but most of the dodge is gone
    }

    function test_blockVolumeTracksEachSideAndResets() public {
        _routerBuy(bob, t, 1 ether);
        // native AVAX (address 0) sorts first: a buy is zeroForOne
        assertEq(surge.blockVolume(_id(key), true), 1 ether);
        assertEq(surge.blockVolume(_id(key), false), 0);
        uint256 q1 = surge.quoteSurge(_id(key), address(t), address(0), true, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(surge.blockVolume(_id(key), true), 0);
        uint256 q0 = surge.quoteSurge(_id(key), address(t), address(0), true, 1 ether);
        assertGt(q1, q0); // the block's earlier volume counts toward the quote
    }
}
