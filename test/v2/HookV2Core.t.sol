// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../../contracts/v2/HookModuleRegistry.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {KingOfTheHillModule} from "../../contracts/v2/modules/KingOfTheHillModule.sol";
import {MaxPerWalletModule} from "../../contracts/v2/modules/MaxPerWalletModule.sol";
import {V2Base} from "./V2Base.t.sol";
import {ProbeModule} from "./V2Mocks.sol";

/// Core hook rules, registry auth/deprecation/kill, failure isolation, module primitives and gas.
contract HookV2CoreTest is V2Base {
    using StateLibrary for IPoolManager;

    uint16 constant ALL_SWAP = ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY;

    function _ids(uint32 a) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](1);
        ids[0] = a;
    }

    function _cfgs(bytes memory a) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = a;
    }

    function _probe(uint16 caps) internal returns (ProbeModule p, uint32 id) {
        p = new ProbeModule(address(hook), caps, 0);
        id = modules.addModule(address(p), '{"name":"probe"}');
    }

    function _launchProbe(uint16 caps) internal returns (ProbeModule p, HookTokenV2 t, PoolKey memory key) {
        uint32 id;
        (p, id) = _probe(caps);
        t = _launch(_ids(id), _cfgs(""), 100);
        key = _graduate(t);
    }

    // ---------------------------------------------------------------- core rules

    function test_coreFeesAndProtocolClaim() public {
        HookTokenV2 t = _launch(new uint32[](0), new bytes[](0), 100);
        _graduate(t);
        assertFalse(t.transferRules()); // no transfer module: the token never calls out
        uint256 p0 = hook.claimable(hook.PROTOCOL(), NATIVE);
        uint256 c0 = hook.claimable(creator, NATIVE);
        uint256 got = _routerBuy(alice, t, 10 ether);
        assertEq(hook.claimable(hook.PROTOCOL(), NATIVE) - p0, 0.03 ether);
        assertEq(hook.claimable(creator, NATIVE) - c0, 0.1 ether);
        uint256 out = _routerSell(alice, t, got);
        assertGt(out, 9 ether);
        uint256 owed = hook.claimable(hook.PROTOCOL(), NATIVE);
        uint256 b0 = treasury.balance;
        vm.prank(bob); // permissionless, always paid to the launchpad's recipient
        hook.claimProtocol(NATIVE);
        assertEq(treasury.balance - b0, owed);
    }

    function test_exactOutputAndPartialFillBlocked() public {
        HookTokenV2 t = _launch(new uint32[](0), new bytes[](0), 0);
        PoolKey memory key = _graduate(t);
        vm.expectRevert();
        agg.swap(key, true, int256(1 ether)); // exact output
        (uint160 sp,,,) = PM.getSlot0(_id(key));
        vm.expectRevert();
        agg.swapWithLimit(key, true, -int256(1 ether), sp - sp / 100); // price-limited buy
    }

    function test_outsideLiquidityFullRangeOnly() public {
        (ProbeModule p,, PoolKey memory key) = _launchProbe(ModuleCaps.LIQUIDITY);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        HookTokenV2 t = HookTokenV2(Currency.unwrap(key.currency1)); // native AVAX is always currency0
        _routerBuy(carol, t, 50 ether);
        vm.startPrank(carol);
        t.approve(address(lp), type(uint256).max);
        int24 lo = TickMath.minUsableTick(60);
        int24 hi = TickMath.maxUsableTick(60);
        vm.expectRevert();
        lp.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(lo + 60, hi, 1e18, 0), "");
        lp.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(lo, hi, 1e18, 0), "");
        lp.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, -1e18, 0), "");
        vm.stopPrank();
        assertEq(p.calls(), 2); // add + remove reached the module
    }

    // ---------------------------------------------------------------- context: identity, per-tx volume, price

    function test_contextTrustedIdentityAndTxVolume() public {
        (ProbeModule p, HookTokenV2 t, PoolKey memory key) = _launchProbe(ModuleCaps.BEFORE_SWAP);
        _routerBuy(alice, t, 1 ether);
        assertEq(p.lastTrader(), alice);
        // the curve buys that graduated the pool count too (shared counters; forge runs the test as one tx)
        uint256 s1 = p.lastTxSwaps();
        uint256 v1 = p.lastTxVolume();
        assertGt(s1, 1);
        assertGt(p.lastPrice(), 0);
        vm.prank(bob);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp, hex"c0ffee");
        assertEq(p.lastExtra(), hex"c0ffee");
        agg.swap(key, true, -int256(1 ether));
        assertEq(p.lastTrader(), address(0)); // untrusted caller: no identity
        TwoBuys two = new TwoBuys(address(router));
        vm.deal(address(two), 10 ether);
        two.run(address(t));
        // forge runs the whole test as ONE transaction, so the transient counters keep adding up:
        // 2 more buys + 2 = 4 swaps, 1+1+1+2 = 5 AVAX of buys since the first.
        assertEq(p.lastTxSwaps(), s1 + 4);
        assertEq(p.lastTxVolume(), v1 + 5 ether);
    }

    // ---------------------------------------------------------------- registry

    function test_registryAuth() public {
        ProbeModule p = new ProbeModule(address(hook), ModuleCaps.BEFORE_SWAP, 0);
        vm.startPrank(alice);
        vm.expectRevert();
        modules.addModule(address(p), "");
        vm.expectRevert();
        modules.setDeprecated(kothId, true);
        vm.expectRevert();
        modules.disable(kothId);
        vm.stopPrank();
        vm.expectRevert(AvaxHookV2.NotRegistry.selector);
        hook.disableModule(address(koth));
        // a module bound to another hook, a duplicate, or one without capabilities is refused
        ProbeModule other = new ProbeModule(address(hook), 0, 0);
        vm.expectRevert(HookModuleRegistry.BadArgs.selector);
        modules.addModule(address(other), "");
        vm.expectRevert(HookModuleRegistry.BadArgs.selector);
        modules.addModule(address(koth), "");
        // ownership goes to the Safe in two steps
        modules.transferOwnership(SAFE);
        vm.prank(SAFE);
        modules.acceptOwnership();
        assertEq(modules.owner(), SAFE);
    }

    function test_deprecatedModuleKeepsLivePoolsRunning() public {
        (HookTokenV2 t,) = _kothMpw(1 ether, 0);
        modules.setDeprecated(kothId, true);
        // new launches can't pick it
        bytes[] memory c = _cfgs(_kothCfg(1 ether, 500, 50, 0, false));
        vm.expectRevert(HookModuleRegistry.NotActive.selector);
        this.launchExt(_ids(kothId), c);
        // the live pool still runs it
        _routerBuy(alice, t, pad.getLaunch(address(t)).target); // beats the King crowned on the curve
        (address k,,,) = koth.currentKing(address(t));
        assertEq(k, alice);
        modules.setDeprecated(kothId, false);
        this.launchExt(_ids(kothId), c);
    }

    function test_disabledModuleIsSkippedEverywhere() public {
        (HookTokenV2 t,) = _kothMpw(1 ether, 0);
        _routerBuy(alice, t, pad.getLaunch(address(t)).target); // beats the King crowned on the curve
        modules.disable(kothId);
        assertTrue(hook.disabled(address(koth)));
        _routerBuy(bob, t, 10 ether); // no King fee, no crown change
        assertEq(hook.claimable(alice, NATIVE), 0);
        (address k,,,) = koth.currentKing(address(t));
        assertEq(k, alice);
        vm.expectRevert(HookModuleRegistry.NotActive.selector);
        modules.disable(kothId);
    }

    function test_conflictsAndDuplicatesRefused() public {
        MaxPerWalletModule mpw2 = new MaxPerWalletModule(address(hook));
        uint32 id2 = modules.addModule(address(mpw2), "");
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (mpwId, id2);
        (cfgs[0], cfgs[1]) = (_mpwCfg(100, 0), _mpwCfg(100, 0));
        vm.expectRevert(abi.encodeWithSelector(AvaxHookV2.ModuleConflict.selector, id2));
        this.launchExt(ids, cfgs);
        (ids[0], ids[1]) = (kothId, kothId);
        (cfgs[0], cfgs[1]) = (_kothCfg(1, 500, 50, 0, false), _kothCfg(1, 500, 50, 0, false));
        vm.expectRevert(abi.encodeWithSelector(AvaxHookV2.ModuleConflict.selector, kothId));
        this.launchExt(ids, cfgs);
        vm.expectRevert(HookModuleRegistry.UnknownModule.selector);
        this.launchExt(_ids(999), _cfgs(""));
        vm.expectRevert(); // invalid config
        this.launchExt(_ids(kothId), _cfgs(_kothCfg(0, 500, 50, 0, false)));
    }

    function _cool(HookTokenV2 t) internal {
        address[8] memory a = [address(PM), address(hook), address(router), address(pad), address(t), address(koth), address(mpw), alice];
        for (uint256 i; i < a.length; ++i) {
            vm.cool(a[i]);
        }
        (address[] memory mods,) = lens.modulesOf(address(t));
        for (uint256 i; i < mods.length; ++i) {
            vm.cool(mods[i]);
        }
        vm.cool(address(modules));
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs) external returns (HookTokenV2) {
        return _launch(ids, cfgs, 0);
    }

    // ---------------------------------------------------------------- failure isolation

    function test_brokenModuleBlocksBuysButNeverSells() public {
        (ProbeModule p, HookTokenV2 t,) = _launchProbe(ALL_SWAP);
        uint256 got = _routerBuy(alice, t, 5 ether);
        p.set(true, 0, 0);
        vm.prank(bob);
        vm.expectRevert();
        router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp, "");
        uint256 out = _routerSell(alice, t, got); // swap callbacks and the settle transfer are isolated
        assertGt(out, 4.5 ether);
        vm.prank(alice);
        vm.expectRevert(); // a wallet-to-wallet transfer is the rule's business
        t.transfer(bob, 1);
    }

    function test_blocksSellsModuleCanRefuseSells() public {
        (ProbeModule p, HookTokenV2 t,) = _launchProbe(ALL_SWAP | ModuleCaps.BLOCKS_SELLS);
        uint256 got = _routerBuy(alice, t, 5 ether);
        p.set(true, 0, 0);
        vm.startPrank(alice);
        t.approve(address(router), got);
        vm.expectRevert();
        router.sell(address(t), got, 0, block.timestamp, "");
        vm.stopPrank();
    }

    /// Over-cap credits are scaled down to the 25% cap on both sides, never a revert (rules M).
    function test_overCapCreditsAreScaledToTheCap() public {
        (ProbeModule p, HookTokenV2 t,) = _launchProbe(ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        uint256 got = _routerBuy(alice, t, 5 ether);
        p.set(false, 5_000, 0); // asks for 50% > MAX_MODULE_CUT_BPS
        _routerBuy(bob, t, 1 ether);
        assertEq(hook.claimable(address(p), NATIVE), 0.25 ether); // 25% of the buy input
        uint256 k0 = hook.claimable(address(p), Currency.wrap(address(t)));
        uint256 out = _routerSell(alice, t, got);
        assertGt(out, 2.5 ether);
        assertEq(hook.claimable(address(p), Currency.wrap(address(t))) - k0, got / 4); // 25% of the sell input
        // 25% of the gross sell output (seller gets the rest minus 0.3% protocol + 1% creator)
        uint256 nq = hook.claimable(address(p), NATIVE) - 0.25 ether;
        assertApproxEqRel(nq, (out * 2_500) / (10_000 - 2_500 - 130), 1e12);
    }

    function test_extraFeeCapped() public {
        (ProbeModule p, HookTokenV2 t,) = _launchProbe(ModuleCaps.BEFORE_SWAP);
        p.set(false, 0, 900_000); // asks for 90% LP fee
        uint256 got = _routerBuy(alice, t, 1 ether);
        assertGt(got, 0); // swap goes through at the 30% ceiling
    }

    // ---------------------------------------------------------------- module primitives

    function test_moduleCreditsAndModuleSwapBurn() public {
        (ProbeModule p, HookTokenV2 t, PoolKey memory key) = _launchProbe(ModuleCaps.BEFORE_SWAP);
        p.set(false, 1_000, 0); // 10% of each buy to the module
        _routerBuy(alice, t, 10 ether);
        assertEq(hook.claimable(address(p), NATIVE), 1 ether);
        p.set(false, 0, 0);
        uint256 dead0 = t.balanceOf(DEAD);
        (uint256 spent, uint256 out) = p.swapOwn(key, true, 1 ether, true);
        assertEq(spent, 1 ether);
        assertEq(t.balanceOf(DEAD) - dead0, out);
        assertEq(hook.claimable(address(p), NATIVE), 0);
        vm.expectRevert(AvaxHookV2.NotModule.selector);
        hook.moduleSwap(key, true, 1, TickMath.MIN_SQRT_PRICE + 1, true);
        // claims can be moved (pots, rewards)
        p.set(false, 1_000, 0);
        _routerBuy(alice, t, 1 ether);
        vm.prank(address(p));
        hook.transferClaim(NATIVE, carol, 0.1 ether);
        assertEq(hook.claimable(carol, NATIVE), 0.1 ether);
    }

    // ---------------------------------------------------------------- gas

    function test_gasPerSwap() public {
        HookTokenV2 t0 = _launch(new uint32[](0), new bytes[](0), 100);
        _graduate(t0);
        uint32[] memory ids1 = _ids(kothId);
        bytes[] memory c1 = _cfgs(_kothCfg(1 ether, 500, 50, 3600, false));
        HookTokenV2 t1 = _launch(ids1, c1, 100);
        _graduate(t1);
        (, uint32 probeId) = _probe(ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER);
        uint32[] memory ids3 = new uint32[](3);
        bytes[] memory c3 = new bytes[](3);
        (ids3[0], ids3[1], ids3[2]) = (kothId, mpwId, probeId);
        (c3[0], c3[1], c3[2]) = (c1[0], _mpwCfg(5_000, 0), bytes(""));
        HookTokenV2 t3 = _launch(ids3, c3, 100);
        _graduate(t3);
        HookTokenV2[3] memory ts = [t0, t1, t3];
        uint256[3] memory n = [uint256(0), 1, 3];
        for (uint256 i; i < 3; ++i) {
            _routerBuy(carol, ts[i], 3 ether); // a King to pay
            _cool(ts[i]);
            uint256 g = gasleft();
            uint256 got = _routerBuy(alice, ts[i], 1 ether);
            uint256 gBuy = g - gasleft();
            vm.startPrank(alice);
            ts[i].approve(address(router), got);
            _cool(ts[i]);
            g = gasleft();
            router.sell(address(ts[i]), got, 0, block.timestamp, "");
            uint256 gSell = g - gasleft();
            vm.stopPrank();
            console2.log("modules / router buy gas / router sell gas", n[i], gBuy, gSell);
        }
    }

}

contract TwoBuys {
    IRouterV2Buy immutable r;

    constructor(address _r) {
        r = IRouterV2Buy(_r);
    }

    receive() external payable {}

    function run(address token) external {
        r.buy{value: 1 ether}(token, 1 ether, 0, address(0), block.timestamp, "");
        r.buy{value: 2 ether}(token, 2 ether, 0, address(0), block.timestamp, "");
    }
}

interface IRouterV2Buy {
    function buy(address, uint256, uint256, address, uint256, bytes calldata) external payable returns (uint256);
}
