// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {AntiBundleModule} from "../../contracts/v2/modules/AntiBundleModule.sol";
import {MultiSwapper} from "./NewModulesBase.t.sol";
import {EarlyBlocksBase} from "./EarlyBlocksBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AvaxHookRouterV2} from "../../contracts/v2/AvaxHookRouterV2.sol";

/// Buys and sells back in one transaction (the "fill the block for the fees" griefer).
contract RoundTripper {
    AvaxHookRouterV2 immutable router;

    constructor(AvaxHookRouterV2 _router) {
        router = _router;
    }

    receive() external payable {}

    function roundTrip(address token, uint256 a) external {
        uint256 got = router.buy{value: a}(token, a, 0, address(0), block.timestamp, "");
        IERC20(token).approve(address(router), got);
        router.sell(token, got, 0, block.timestamp, "");
    }

    function buyKeepSome(address token, uint256 a, uint256 keepBps) external {
        uint256 got = router.buy{value: a}(token, a, 0, address(0), block.timestamp, "");
        uint256 sell = got - (got * keepBps) / 10_000;
        IERC20(token).approve(address(router), sell);
        router.sell(token, sell, 0, block.timestamp, "");
    }
}

/// Anti-bundle in the live hook. Isolated: each top-level call is its own transaction (the rule counts
/// buying transactions per block).
/// forge-config: default.isolate = true
contract AntiBundleModuleTest is EarlyBlocksBase {
    AntiBundleModule ab;
    uint32 abId;

    function setUp() public override {
        super.setUp();
        ab = new AntiBundleModule(address(hook));
        abId = modules.addModule(address(ab), '{"name":"Anti-bundle"}');
    }

    /// Tests count every buy of 0.01% or more (pool buys of 1 AVAX are ~0.035%).
    function _cfg(uint16 maxBuys, uint32 blocks) internal pure returns (bytes memory) {
        return _cfg(maxBuys, blocks, 1);
    }

    function _cfg(uint16 maxBuys, uint32 blocks, uint16 minBps) internal pure returns (bytes memory) {
        return abi.encode(AntiBundleModule.Config(maxBuys, blocks, minBps));
    }

    /// Fills the curve with one buy per block.
    function _graduateSlow(HookTokenV2 t) internal returns (PoolKey memory key) {
        uint256 chunk = uint256(pad.getLaunch(address(t)).target) / 10;
        for (uint256 i; i < 30 && !pad.getLaunch(address(t)).complete; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            _curveBuy(_holder(i), t, chunk);
        }
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        key = pad.poolKey(address(t));
    }

    function test_capabilities() public view {
        assertEq(ab.capabilities(), ModuleCaps.AFTER_SWAP);
        assertEq(ab.conflictGroups(), 0);
    }

    function test_curveBuysPerBlockLimited() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(2, 10)), 0);
        assertTrue(ab.active(address(t)));
        assertEq(ab.buysLeftThisBlock(address(t)), 2);
        _curveBuy(alice, t, 1 ether);
        _curveBuy(bob, t, 1 ether);
        assertEq(ab.buysLeftThisBlock(address(t)), 0);
        vm.deal(carol, 10 ether);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AntiBundleModule.TooManyBuysThisBlock.selector, 2));
        pad.buy{value: 1 ether}(address(t), 0);
        // sells are never refused, even with the block full
        _curveSell(alice, t, t.balanceOf(alice) / 2);
        // next block: room again
        vm.roll(vm.getBlockNumber() + 1);
        _curveBuy(carol, t, 1 ether);
        // after the window: no limit
        vm.roll(vm.getBlockNumber() + 10);
        assertFalse(ab.active(address(t)));
        for (uint256 i; i < 5; ++i) {
            _curveBuy(_holder(100 + i), t, 0.5 ether);
        }
    }

    function test_poolWindowAndEveryRouteCounts() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(2, 20)), 0);
        PoolKey memory key = _graduateSlow(t);
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(ab.active(address(t))); // pool window started at the open
        _routerBuy(alice, t, 1 ether);
        _directBuy(key, 1 ether); // aggregator / direct PoolManager buy counts too
        bytes memory err = _buyError(bob, t, 1 ether);
        assertTrue(_has(err, AntiBundleModule.TooManyBuysThisBlock.selector));
        vm.expectRevert();
        agg.swap(key, true, -int256(1 ether));
        // sells still go through
        _routerSell(alice, t, t.balanceOf(alice));
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(bob, t, 1 ether);
        // pool window over
        vm.roll(vm.getBlockNumber() + 20);
        assertFalse(ab.active(address(t)));
        for (uint256 i; i < 4; ++i) {
            _routerBuy(carol, t, 1 ether);
        }
    }

    function _directBuy(PoolKey memory key, uint256 amt) internal {
        agg.swap(key, true, -int256(amt));
    }

    /// Several buy swaps inside ONE transaction count as one buying transaction.
    function test_splitRouteCountsOnce() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(1, 43_200)), 0);
        _graduateSlow(t);
        vm.roll(vm.getBlockNumber() + 1);
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 10 ether);
        m.buyTwice{value: 2 ether}(address(t), 1 ether, 1 ether);
        _buyReverts(alice, t, 1 ether);
    }

    /// The longest window (43,200 blocks per phase) ends; there is no "forever" any more.
    function test_maxWindowEnds() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(1, 43_200)), 0);
        _graduateSlow(t);
        vm.roll(vm.getBlockNumber() + 43_199);
        assertTrue(ab.active(address(t)));
        _routerBuy(alice, t, 1 ether);
        _buyReverts(bob, t, 1 ether);
        assertEq(ab.buysLeftThisBlock(address(t)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        assertFalse(ab.active(address(t)));
        _routerBuy(alice, t, 1 ether);
        _routerBuy(bob, t, 1 ether);
    }

    /// Audit fix: dust buys under minBuyBps pass uncounted and can't take the block's place.
    function test_dustBuysDontTakeThePlace() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(1, 43_200, 5)), 0); // 0.05%
        for (uint256 b; b < 5; ++b) {
            vm.roll(vm.getBlockNumber() + 1);
            _curveBuy(address(0xBAD), t, 1e9); // dust: passes, not counted
            _curveBuy(address(0xBAD), t, 0.05 ether); // ~0.02%: still under the minimum
            assertEq(ab.buysLeftThisBlock(address(t)), 1);
            _curveBuy(alice, t, 1 ether); // honest buy takes the place
            vm.deal(bob, 2 ether);
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(AntiBundleModule.TooManyBuysThisBlock.selector, 1));
            pad.buy{value: 1 ether}(address(t), 0);
            _curveBuy(address(0xBAD), t, 1e9); // dust still passes after the block is full
        }
    }

    /// Split dust swaps in one transaction that add up to the minimum count once.
    function test_splitSmallSwapsAddUp() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(1, 43_200, 5)), 0);
        _graduateSlow(t);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 rate = _routerBuy(bob, t, 1 ether); // tokens per AVAX right now (takes this block's place)
        vm.roll(vm.getBlockNumber() + 1);
        uint256 each = (SUPPLY * 5 * 2 / 3 / 10_000) * 1 ether / rate; // each swap ~2/3 of the minimum
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 10 ether);
        m.buyTwice{value: 2 * each}(address(t), each, each);
        assertEq(ab.buysLeftThisBlock(address(t)), 0); // together they count
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(alice, t, each); // one alone doesn't
        assertEq(ab.buysLeftThisBlock(address(t)), 1);
    }

    /// The dev buy at launch takes one of the launch block's slots.
    function test_devBuyCounts() public {
        HookTokenV2 t = _launchDev(_cfg(1, 5), 1 ether);
        assertGt(t.balanceOf(creator), 0);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);
        vm.roll(vm.getBlockNumber() + 1);
        _curveBuy(alice, t, 1 ether);
    }

    function testFuzz_neverMoreThanMaxPerBlock(uint8 maxBuys, uint8 tries) public {
        uint16 m = uint16(bound(maxBuys, 1, 6));
        uint256 n = bound(tries, 1, 12);
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(m, 100)), 0);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 ok;
        for (uint256 i; i < n; ++i) {
            address w = _holder(200 + i);
            vm.deal(w, 1 ether);
            vm.prank(w);
            try pad.buy{value: 0.2 ether}(address(t), 0) {
                ++ok;
            } catch {}
        }
        assertEq(ok, n < m ? n : m);
    }

    function test_callbackGas() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(5, 100)), 0);
        IHookModule.SwapContext memory c;
        c.poolId = ab.poolOf(address(t));
        c.isBuy = true;
        c.phase = ModuleCaps.PHASE_CURVE;
        c.amountOut = 1_000_000 ether;
        vm.prank(address(hook));
        uint256 g = gasleft();
        ab.onAfterSwap(c);
        g -= gasleft();
        emit log_named_uint("anti-bundle onAfterSwap gas", g);
        assertLt(g, 40_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        ab.validateConfig(_cfg(0, 10));
        vm.expectRevert();
        ab.validateConfig(_cfg(101, 10));
        vm.expectRevert();
        ab.validateConfig(_cfg(1, 43_201));
        vm.expectRevert();
        ab.validateConfig(_cfg(1, 0)); // no "forever"
        vm.expectRevert();
        ab.validateConfig(_cfg(1, 10, 0));
        vm.expectRevert();
        ab.validateConfig(_cfg(1, 10, 101));
        ab.validateConfig(_cfg(100, 43_200, 100));
        ab.validateConfig(_cfg(1, 1, 1));
    }

    function _launchDev(bytes memory cfg, uint256 devBuy) internal returns (HookTokenV2) {
        return _launchWithDevBuy(_one(abId), _oneCfg(cfg), devBuy);
    }

    /// Audit fix: a buy+sell round trip in one transaction gives its place back (net buying is counted).
    function test_roundTripGivesThePlaceBack() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(1, 43_200, 5)), 0);
        _graduateSlow(t);
        vm.roll(vm.getBlockNumber() + 1);
        RoundTripper g = new RoundTripper(router);
        vm.deal(address(g), 10 ether);
        g.roundTrip(address(t), 4 ether);
        assertEq(ab.buysLeftThisBlock(address(t)), 1, "place given back");
        _routerBuy(alice, t, 4 ether); // the honest buyer gets in
        assertEq(ab.buysLeftThisBlock(address(t)), 0);
        _buyReverts(bob, t, 4 ether); // and the limit still holds
    }

    /// Selling only part back keeps the place while the net is still a counted buy.
    function test_partialSellKeepsThePlace() public {
        HookTokenV2 t = _launch(_one(abId), _oneCfg(_cfg(1, 43_200, 5)), 0);
        _graduateSlow(t);
        vm.roll(vm.getBlockNumber() + 1);
        RoundTripper g = new RoundTripper(router);
        vm.deal(address(g), 10 ether);
        g.buyKeepSome(address(t), 8 ether, 5_000); // keeps half of ~0.28%: still over the 0.05% minimum
        assertEq(ab.buysLeftThisBlock(address(t)), 0, "net buy still counted");
        _buyReverts(alice, t, 4 ether);
    }
}
