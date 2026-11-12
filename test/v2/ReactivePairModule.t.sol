// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {ModuleCaps, IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {ReactivePairModule} from "../../contracts/v2/modules/ReactivePairModule.sol";
import {MultiSwapper} from "./NewModulesBase.t.sol";
import {EarlyBlocksBase} from "./EarlyBlocksBase.t.sol";

/// Reactive pair in the live hook. Isolated: each top-level call is its own transaction (per-tx caps).
/// forge-config: default.isolate = true
contract ReactivePairModuleTest is EarlyBlocksBase {
    ReactivePairModule rp;
    uint32 rpId;

    uint256 constant BASE = 20_000_000 ether; // 2%
    uint256 constant FLOOR = 5_000_000 ether; // 0.5%
    uint256 constant CEIL = 60_000_000 ether; // 6%
    uint256 constant SCALE = 10_000_000 ether; // 1%
    uint32 constant HALF = 1 hours;

    function setUp() public override {
        super.setUp();
        rp = new ReactivePairModule(address(hook));
        rpId = modules.addModule(address(rp), '{"name":"Reactive pair"}');
    }

    /// sensitivity 50%: each 1% of supply of partner net flow moves the cap by half of base.
    function _cfg(address partner) internal pure returns (bytes memory) {
        return abi.encode(ReactivePairModule.Config(200, 50, 600, 5_000, 100, HALF, partner));
    }

    function _launchAs(address who, bytes memory cfg) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Pair";
        a.symbol = "PAIR";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(rpId);
        a.moduleConfigs = _oneCfg(cfg);
        uint256 fee = pad.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        t = HookTokenV2(pad.launch{value: fee}(a));
    }

    function launchAsExt(address who, bytes memory cfg) external returns (HookTokenV2) {
        return _launchAs(who, cfg);
    }

    function _pair() internal returns (HookTokenV2 a, HookTokenV2 b) {
        a = _launchAs(creator, _cfg(address(0)));
        b = _launchAs(creator, _cfg(address(a)));
    }

    /// Books a trade's flow; buys are split into transactions that each fit the token's own cap.
    function _trade(HookTokenV2 tok, bool isBuy, uint256 amount) internal {
        while (isBuy && amount > 0) {
            uint256 cap = rp.currentCap(address(tok));
            uint256 x = amount > cap ? cap : amount;
            _book(tok, true, x);
            amount -= x;
        }
        if (!isBuy) _book(tok, false, amount);
    }

    function _book(HookTokenV2 tok, bool isBuy, uint256 amount) internal {
        IHookModule.SwapContext memory c;
        c.poolId = rp.poolOf(address(tok));
        c.token = address(tok);
        c.isBuy = isBuy;
        if (isBuy) c.amountOut = amount;
        else c.amountIn = amount;
        vm.prank(address(hook));
        rp.onAfterSwap(c);
    }

    function test_capabilities() public view {
        assertEq(rp.capabilities(), ModuleCaps.AFTER_SWAP);
        assertEq(rp.conflictGroups(), ModuleCaps.GROUP_BUY_CAP);
    }

    function test_linkIsMutual() public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        assertEq(rp.partnerOf(address(a)), address(b));
        assertEq(rp.partnerOf(address(b)), address(a));
        assertEq(rp.currentCap(address(a)), BASE);
        assertEq(rp.currentCap(address(b)), BASE);
    }

    function test_linkRefusals() public {
        HookTokenV2 a = _launchAs(creator, _cfg(address(0)));
        // another creator can't link to it
        vm.expectRevert();
        this.launchAsExt(alice, _cfg(address(a)));
        // a token not on this module
        vm.expectRevert();
        this.launchAsExt(creator, _cfg(address(0xBEEF)));
        // once linked, no third token can join
        _launchAs(creator, _cfg(address(a)));
        vm.expectRevert();
        this.launchAsExt(creator, _cfg(address(a)));
    }

    function test_unlinkedIsPlainBase() public {
        HookTokenV2 a = _launchAs(creator, _cfg(address(0)));
        _trade(a, true, BASE);
        assertEq(rp.currentCap(address(a)), BASE);
        assertEq(rp.netFlow(address(a)), int256(BASE));
    }

    function test_partnerBuyingWidensSellingNarrows() public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        _trade(a, true, SCALE); // A net +1%: B's cap 1.5 x base
        assertEq(rp.currentCap(address(b)), (BASE * 3) / 2);
        assertEq(rp.currentCap(address(a)), BASE); // B's flow is still 0
        _trade(a, true, 2 * SCALE); // +3%: 2.5 x base
        assertEq(rp.currentCap(address(b)), (BASE * 5) / 2);
        _trade(a, true, 5 * SCALE); // +8%: 5 x base > ceiling
        assertEq(rp.currentCap(address(b)), CEIL);
        _trade(a, false, 10 * SCALE); // net −2%: 0 x base -> floor
        assertEq(rp.netFlow(address(a)), -int256(2 * SCALE));
        assertEq(rp.currentCap(address(b)), FLOOR);
        _trade(a, true, SCALE); // −1%: half of base
        assertEq(rp.currentCap(address(b)), BASE / 2);
    }

    function test_flowDecaysWithHalfLife() public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        _trade(a, true, 4 * SCALE);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + HALF);
        assertEq(rp.netFlow(address(a)), int256(2 * SCALE));
        assertEq(rp.currentCap(address(b)), 2 * BASE);
        vm.warp(t0 + HALF + HALF / 2); // linear between halvings: 2 -> 1.5
        assertEq(rp.netFlow(address(a)), int256((3 * SCALE) / 2));
        vm.warp(t0 + 100 * HALF);
        assertEq(rp.netFlow(address(a)), 0);
        assertEq(rp.currentCap(address(b)), BASE);
        // negative flow decays the same way
        _trade(a, false, 2 * SCALE);
        vm.warp(vm.getBlockTimestamp() + HALF);
        assertEq(rp.netFlow(address(a)), -int256(SCALE));
    }

    function test_curveBuysCappedAndBooked() public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(); // ~8% of supply in one curve buy against a 2% cap
        pad.buy{value: 20 ether}(address(b), 0);
        _curveBuy(alice, a, 4 ether); // ~1.8% of A
        int256 fa = rp.netFlow(address(a));
        assertGt(fa, int256(SCALE));
        assertGt(rp.currentCap(address(b)), (BASE * 3) / 2);
        _curveBuy(alice, b, 7 ether); // ~3% of B fits now
        _curveSell(alice, a, a.balanceOf(alice));
        assertLt(rp.netFlow(address(a)), int256(SCALE / 100));
    }

    function test_poolPhaseAllRoutes() public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        PoolKey memory kb = _graduateCapped(b, (BASE * 95) / 100, 0);
        PoolKey memory ka = _graduateCapped(a, (BASE * 95) / 100, 0);
        vm.warp(vm.getBlockTimestamp() + 100 * HALF); // flows gone
        assertEq(rp.currentCap(address(b)), BASE);
        bytes memory err = _buyError(alice, b, 150 ether);
        assertTrue(_has(err, ReactivePairModule.BuyCapExceeded.selector));
        // an aggregator buy of A counts toward A's flow and widens B
        agg.swap(ka, true, -int256(60 ether));
        assertGt(rp.netFlow(address(a)), 0);
        assertGt(rp.currentCap(address(b)), BASE);
        vm.expectRevert();
        agg.swap(kb, true, -int256(400 ether));
        _routerBuy(bob, b, 50 ether);
    }

    function test_splitBuysInOneTxCountTogether() public {
        (, HookTokenV2 b) = _pair();
        _graduateCapped(b, (BASE * 95) / 100, 0);
        vm.warp(vm.getBlockTimestamp() + 100 * HALF);
        MultiSwapper m = new MultiSwapper(router);
        vm.deal(address(m), 200 ether);
        try m.buyTwice{value: 120 ether}(address(b), 60 ether, 60 ether) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, ReactivePairModule.BuyCapExceeded.selector));
        }
        _routerBuy(alice, b, 60 ether);
    }

    function testFuzz_capWithinBounds(uint256 x, bool buy, uint32 wait) public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        for (uint256 i; i < 6; ++i) {
            uint256 amt = bound(uint256(keccak256(abi.encode(x, i))), 1, 300_000_000 ether);
            _trade(a, buy || i % 2 == 0, amt);
            vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 3 * HALF));
        }
        uint256 c = rp.currentCap(address(b));
        assertGe(c, FLOOR);
        assertLe(c, CEIL);
        int256 f = rp.netFlow(address(a));
        assertLe(f < 0 ? -f : f, int256(SUPPLY));
    }

    function test_callbackGas() public {
        (HookTokenV2 a, HookTokenV2 b) = _pair();
        _trade(a, true, SCALE);
        _trade(b, true, SCALE);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        IHookModule.SwapContext memory c;
        c.poolId = rp.poolOf(address(b));
        c.isBuy = true;
        c.amountOut = FLOOR;
        vm.prank(address(hook));
        uint256 g = gasleft();
        rp.onAfterSwap(c);
        g -= gasleft();
        emit log_named_uint("reactive-pair onAfterSwap gas", g);
        assertLt(g, 60_000);
    }

    function test_configBounds() public {
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(9, 5, 600, 5_000, 100, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 201, 600, 5_000, 100, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 199, 5_000, 100, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 2_001, 5_000, 100, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 600, 0, 100, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 600, 100_001, 100, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 600, 5_000, 0, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 600, 5_000, 5_001, HALF, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 600, 5_000, 100, 59, address(0))));
        vm.expectRevert();
        rp.validateConfig(abi.encode(ReactivePairModule.Config(200, 50, 600, 5_000, 100, 7 days + 1, address(0))));
        rp.validateConfig(abi.encode(ReactivePairModule.Config(1_000, 1_000, 2_000, 100_000, 5_000, 7 days, address(1))));
    }
}
