// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {KingOfTheHillModule} from "../../contracts/v2/modules/KingOfTheHillModule.sol";
import {IHookModule} from "../../contracts/v2/interfaces/IHookModule.sol";
import {V2Base} from "./V2Base.t.sol";

contract KingOfTheHillModuleTest is V2Base {
    HookTokenV2 t;
    PoolKey key;

    event Crowned(address indexed token, address indexed king, uint256 amount, uint256 timestamp);
    event Dethroned(address indexed token, address indexed king, KingOfTheHillModule.Reason reason);
    event KingPaid(address indexed token, address indexed king, uint256 amount);

    function setUp() public override {
        super.setUp();
        (t, key) = _kothMpw(1 ether, 3600);
        // Curve buys run the modules too, so a graduation wallet holds the crown now; these tests start
        // the pool phase without a King (curve crowning: test/v2/CurveModules.t.sol).
        (address k,,,) = koth.currentKing(address(t));
        if (k != address(0)) {
            vm.prank(k);
            t.transfer(DEAD, 1); // any outgoing transfer gives up the crown
        }
    }

    function _king() internal view returns (address k, uint256 w, uint256 bar) {
        (k, w, bar,) = koth.currentKing(address(t));
    }

    function test_launchedWithBothModules() public view {
        (address[] memory mods, uint16[] memory caps) = lens.modulesOf(address(t));
        assertEq(mods.length, 2);
        assertEq(mods[0], address(koth));
        assertEq(mods[1], address(mpw));
        assertEq(caps[0], koth.capabilities());
        assertTrue(t.transferRules());
        assertTrue(t.tradingOpen());
        assertTrue(hook.isOpen(_id(key)));
        assertEq(hook.REQUIRED_FLAGS(), _requiredFlags());
    }

    function test_crownAndBeatByFivePercent() public {
        vm.expectEmit(true, true, false, true, address(koth));
        emit Crowned(address(t), alice, 2 ether, block.timestamp);
        _routerBuy(alice, t, 2 ether);
        (address k, uint256 w,) = _king();
        assertEq(k, alice);
        assertEq(w, 2 ether);
        assertEq(koth.requiredToCrown(address(t)), 2.1 ether);

        _routerBuy(bob, t, 2.09 ether); // +4.5%: not enough
        (k,,) = _king();
        assertEq(k, alice);

        vm.expectEmit(true, true, false, true, address(koth));
        emit Dethroned(address(t), alice, KingOfTheHillModule.Reason.Beaten);
        _routerBuy(bob, t, 2.1 ether);
        (k, w,) = _king();
        assertEq(k, bob);
        assertEq(w, 2.1 ether);
    }

    function test_belowMinimumOrCreatorCantCrown() public {
        _routerBuy(carol, t, 0.99 ether);
        (address k,,) = _king();
        assertEq(k, address(0));
        _routerBuy(creator, t, 5 ether); // creatorCanBeKing = false
        (k,,) = _king();
        assertEq(k, address(0));
    }

    function test_barDecaysByHalfPerPeriod() public {
        uint256 t0 = vm.getBlockTimestamp();
        _routerBuy(alice, t, 4 ether);
        vm.warp(t0 + 1800);
        (,, uint256 bar) = _king();
        assertEq(bar, 3 ether); // halfway to the first halving
        vm.warp(t0 + 3600);
        (,, bar) = _king();
        assertEq(bar, 2 ether);
        _routerBuy(bob, t, 2.09 ether);
        (address k,,) = _king();
        assertEq(k, alice);
        _routerBuy(bob, t, 2.1 ether);
        (k,,) = _king();
        assertEq(k, bob);
        vm.warp(t0 + 3600 * 200);
        (,, bar) = _king();
        assertEq(bar, 0);
        assertEq(koth.requiredToCrown(address(t)), 1 ether); // never below the minimum
    }

    function test_kingEarnsOnBuysAndSellsAndClaims() public {
        uint256 paid0 = koth.hill(address(t)).totalPaid; // curve-phase Kings were paid too
        _routerBuy(alice, t, 20 ether);
        assertEq(hook.claimable(alice, NATIVE), 0); // no King to pay on the crowning buy

        vm.expectEmit(true, true, false, true, address(koth));
        emit KingPaid(address(t), alice, 0.05 ether);
        uint256 got = _routerBuy(bob, t, 10 ether);
        assertEq(hook.claimable(alice, NATIVE), 0.05 ether);

        uint256 out = _routerSell(bob, t, got);
        // 0.5% of the sell's quote output (before cuts): out = gross * (1 - 0.3% - 1% - 0.5%)
        uint256 gross = (out * 10_000) / (10_000 - 30 - 100 - 50);
        assertApproxEqAbs(hook.claimable(alice, NATIVE), 0.05 ether + gross * 50 / 10_000, 1e12);
        assertEq(koth.hill(address(t)).totalPaid - paid0, hook.claimable(alice, NATIVE));

        uint256 owed = hook.claimable(alice, NATIVE);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        hook.claim(NATIVE, alice);
        assertEq(alice.balance - b0, owed);
        assertEq(hook.claimable(alice, NATIVE), 0);
    }

    function test_dethronedOnRouterSell_noFeeToSelf() public {
        uint256 got = _routerBuy(alice, t, 2 ether);
        vm.prank(alice);
        t.approve(address(router), got);
        vm.expectEmit(true, true, false, true, address(koth));
        emit Dethroned(address(t), alice, KingOfTheHillModule.Reason.Sold);
        vm.prank(alice);
        router.sell(address(t), got / 100, 0, block.timestamp, "");
        (address k,,) = _king();
        assertEq(k, address(0));
        assertEq(hook.claimable(alice, NATIVE), 0);
    }

    function test_dethronedOnAnyTransfer() public {
        _routerBuy(alice, t, 2 ether);
        // a zero-value transferFrom needs no allowance: it must not dethrone
        vm.prank(bob);
        t.transferFrom(alice, bob, 0);
        (address k,,) = _king();
        assertEq(k, alice);

        vm.expectEmit(true, true, false, true, address(koth));
        emit Dethroned(address(t), alice, KingOfTheHillModule.Reason.Transferred);
        vm.prank(alice);
        t.transfer(carol, 1);
        (k,,) = _king();
        assertEq(k, address(0));
    }

    function test_aggregatorBuyCantCrownButPaysKing() public {
        // KotH alone: the setUp pool also runs MaxPerWallet (forever), which since the 2026-11-12 claims-bypass
        // guard refuses direct PoolManager buys outright (RouterOnly)
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        (ids[0], cfgs[0]) = (kothId, _kothCfg(1 ether, 500, 50, 3600, false));
        t = _launch(ids, cfgs, 100);
        key = _graduate(t);
        (address k0,,,) = koth.currentKing(address(t));
        if (k0 != address(0)) {
            vm.prank(k0);
            t.transfer(DEAD, 1); // start without a King, as in setUp
        }
        _routerBuy(alice, t, 2 ether);
        agg.swap(key, true, -int256(50 ether)); // direct PoolManager buy, no trusted identity
        (address k, uint256 w,) = _king();
        assertEq(k, alice);
        assertEq(w, 2 ether);
        assertEq(hook.claimable(alice, NATIVE), 0.25 ether);
    }

    function test_aggregatorSellByKingDethrones() public {
        uint256 got = _routerBuy(alice, t, 2 ether);
        vm.prank(alice);
        t.approve(address(agg), got);
        agg.sellFrom(key, address(t), alice, got / 2);
        (address k,,) = _king();
        assertEq(k, address(0));
    }

    function test_kingCanRefreshOwnBar() public {
        _routerBuy(alice, t, 2 ether);
        _routerBuy(alice, t, 2.2 ether);
        (address k, uint256 w,) = _king();
        assertEq(k, alice);
        assertEq(w, 2.2 ether);
        assertEq(hook.claimable(alice, NATIVE), 0.011 ether); // paid herself on her own buy
    }

    function test_configValidation() public {
        vm.expectRevert();
        koth.validateConfig(_kothCfg(0, 500, 50, 0, false));
        vm.expectRevert();
        koth.validateConfig(_kothCfg(1, 500, 201, 0, false));
        vm.expectRevert();
        koth.validateConfig(_kothCfg(1, 500, 50, 59, false));
        koth.validateConfig(_kothCfg(1, 500, 50, 0, true));
    }

    function test_onlyHookCanCall() public {
        IHookModule.SwapContext memory ctx;
        vm.expectRevert();
        koth.onBeforeSwap(ctx);
        vm.expectRevert();
        koth.onTransfer(_id(key), address(t), alice, alice, bob, 1);
    }
}
