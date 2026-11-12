// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {QuoteRegistry} from "../../contracts/QuoteRegistry.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {SlidingCapsModule} from "../../contracts/v2/modules/SlidingCapsModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// forge-config: default.isolate = true
contract SlidingCapsModuleTest is NewModulesBase {
    SlidingCapsModule sc;
    uint32 scId;
    HookTokenV2 t;
    PoolKey key;
    MultiSwapper multi;

    function setUp() public override {
        super.setUp();
        sc = new SlidingCapsModule(address(hook));
        scId = modules.addModule(address(sc), '{"name":"Sliding caps"}');
        // Caps don't have to loosen with the market cap; this test config keeps launch (the curve, which ends
        // near $50k) loose and tightens above $100k so the pool tests can mock their way between levels.
        (t, key) = _launchOne(scId, _config()); // 40 curve buys of at most ~8%
        multi = new MultiSwapper(router);
        vm.deal(address(multi), 1000 ether);
    }

    function _config() internal pure returns (bytes memory) {
        SlidingCapsModule.Level[] memory l = new SlidingCapsModule.Level[](3);
        l[0] = SlidingCapsModule.Level(100_000, 10, 5); // from $100k: 0.1% / 0.05%
        l[1] = SlidingCapsModule.Level(1_000_000, 50, 50); // from $1M: 0.5% / 0.5%
        l[2] = SlidingCapsModule.Level(10_000_000, 0, 0); // from $10M: no caps
        return abi.encode(SlidingCapsModule.Config(1000, 1000, l)); // launch: 10% / 10%
    }

    /// Mocks AVAX/USD so the token's market cap is about `usd` dollars.
    function _setMc(uint256 usd) internal {
        _mockAvaxUsd(1e24); // $1M per AVAX: market cap in whole dollars = 1e6 x market cap in AVAX
        (, uint256 mcAt1e6,,) = sc.currentCaps(address(t));
        _mockAvaxUsd((usd * 1e24) / mcAt1e6);
    }

    function _level() internal view returns (uint256 lvl) {
        (lvl,,,) = sc.currentCaps(address(t));
    }

    function test_capabilities() public view {
        assertEq(sc.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.BLOCKS_SELLS);
        assertEq(sc.conflictGroups(), ModuleCaps.GROUP_BUY_CAP | ModuleCaps.GROUP_SELL_CAP);
        (uint64[] memory mc, uint16[] memory b, uint16[] memory s) = sc.levels(address(t));
        assertEq(mc.length, 3);
        assertEq(b[0], 1000);
        assertEq(s[1], 5);
        assertEq(b[3], 0);
    }

    function test_capsSlideWithMarketCap() public {
        address h = _holder(0);
        uint256 sell = 1_000_000 ether; // 0.1%

        _setMc(200_000);
        assertEq(_level(), 1);
        assertTrue(_has(_buyError(alice, t, 10 ether), SlidingCapsModule.BuyCapExceeded.selector)); // ~0.2%
        assertTrue(_has(_sellError(h, t, sell), SlidingCapsModule.SellCapExceeded.selector));
        _routerBuy(alice, t, 2 ether);
        _routerSell(h, t, 400_000 ether);

        _setMc(2_000_000);
        assertEq(_level(), 2);
        _routerBuy(alice, t, 10 ether);
        _routerSell(h, t, sell);
        assertTrue(_has(_sellError(h, t, 6_000_000 ether), SlidingCapsModule.SellCapExceeded.selector));

        _setMc(50_000_000);
        assertEq(_level(), 3);
        _routerSell(h, t, 20_000_000 ether); // 2%: no cap any more

        _setMc(200_000); // the market cap fell: back to the tight caps
        assertEq(_level(), 1);
        assertTrue(_has(_sellError(h, t, sell), SlidingCapsModule.SellCapExceeded.selector));

        _setMc(50_000); // below the first level: launch caps
        assertEq(_level(), 0);
        _routerSell(h, t, 20_000_000 ether);
    }

    function test_stalePriceMeansLaunchLevel() public {
        _setMc(200_000);
        assertEq(_level(), 1);
        vm.mockCallRevert(address(LIVE_QUOTES), abi.encodeWithSelector(QuoteRegistry.usdPrice.selector, address(0)), "stale");
        assertEq(_level(), 0);
        _routerBuy(alice, t, 10 ether); // launch caps (10%) apply
    }

    function test_perTransactionTotals() public {
        _setMc(200_000);
        try multi.buyTwice{value: 8 ether}(address(t), 4 ether, 4 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, SlidingCapsModule.BuyCapExceeded.selector));
        }
        address h = _holder(0);
        vm.prank(h);
        t.transfer(address(multi), 1_000_000 ether);
        try multi.sellTwice(address(t), 300_000 ether, 300_000 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, SlidingCapsModule.SellCapExceeded.selector));
        }
        multi.sellTwice(address(t), 200_000 ether, 200_000 ether);
    }

    /// A transaction's level is fixed at its first swap: pushing the price over a threshold mid-way doesn't
    /// unlock looser caps for the rest of the same transaction.
    function test_levelFixedPerTransaction() public {
        _setMc(998_500); // just under $1M (level 1: 0.1% per buy; level 2: 0.5%)
        uint256 snap = vm.snapshotState();
        _routerBuy(alice, t, 4 ether);
        assertEq(_level(), 2); // one 4 AVAX buy lifts the market cap past $1M
        vm.revertToState(snap);
        try multi.buyTwice{value: 8 ether}(address(t), 4 ether, 4 ether) {
            fail(); // the second buy would fit level 2's cap, but the transaction is held to level 1
        } catch (bytes memory err) {
            assertTrue(_has(err, SlidingCapsModule.BuyCapExceeded.selector));
        }
    }

    /// On the curve the level comes from the curve price.
    function test_curvePhase() public {
        uint256 p0 = LIVE_QUOTES.usdPrice(address(0));
        HookTokenV2 t2 = _launch(_one(scId), _oneCfg(_config()), 0);
        (uint256 lvl,,,) = sc.currentCaps(address(t2));
        assertEq(lvl, 0); // no pool price yet
        // the curve starts near a $2.5k market cap: an 80x AVAX price puts it around $200k (level 1)
        _mockAvaxUsd(p0 * 80);
        vm.prank(alice);
        vm.expectRevert(); // ~0.45% of supply > 0.1%
        pad.buy{value: 1 ether}(address(t2), 0);
        vm.prank(alice);
        pad.buy{value: 0.1 ether}(address(t2), 0);
        vm.prank(alice);
        pad.buy{value: 0.1 ether}(address(t2), 0);
        uint256 bal = t2.balanceOf(alice); // ~0.088%
        vm.prank(alice);
        vm.expectRevert(); // > 0.05%
        pad.sell(address(t2), bal, 0);
        vm.prank(alice);
        pad.sell(address(t2), 400_000 ether, 0);
        vm.clearMockedCalls();
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t2), 0); // real price: ~$2.5k, launch level
    }

    function test_configBounds() public {
        SlidingCapsModule.Level[] memory l = new SlidingCapsModule.Level[](2);
        l[0] = SlidingCapsModule.Level(100, 10, 10);
        l[1] = SlidingCapsModule.Level(100, 10, 10); // not increasing
        vm.expectRevert();
        sc.validateConfig(abi.encode(SlidingCapsModule.Config(10, 10, l)));
        SlidingCapsModule.Level[] memory six = new SlidingCapsModule.Level[](6);
        for (uint256 i; i < 6; ++i) six[i] = SlidingCapsModule.Level(uint64(1000 * (i + 1)), 10, 10);
        vm.expectRevert();
        sc.validateConfig(abi.encode(SlidingCapsModule.Config(10, 10, six)));
        vm.expectRevert(); // caps nothing
        sc.validateConfig(abi.encode(SlidingCapsModule.Config(0, 0, new SlidingCapsModule.Level[](0))));
        vm.expectRevert();
        sc.validateConfig(abi.encode(SlidingCapsModule.Config(10_001, 0, new SlidingCapsModule.Level[](0))));
        SlidingCapsModule.Level[] memory five = new SlidingCapsModule.Level[](5);
        for (uint256 i; i < 5; ++i) five[i] = SlidingCapsModule.Level(uint64(1000 * (i + 1)), 0, 10);
        sc.validateConfig(abi.encode(SlidingCapsModule.Config(10, 0, five)));
    }
}
