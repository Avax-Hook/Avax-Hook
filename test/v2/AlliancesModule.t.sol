// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {AlliancesModule} from "../../contracts/v2/modules/AlliancesModule.sol";
import {MockRewardToken} from "./NewModulesBase.t.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract AlliancesModuleTest is ListsAccessBase {
    AlliancesModule am;
    uint32 amId;
    MockRewardToken ally1;
    MockRewardToken rival1;
    uint256 constant AMIN = 10 ether;
    uint256 constant RMIN = 5 ether;
    address otherCreator = makeAddr("otherCreator");

    function setUp() public override {
        super.setUp();
        am = new AlliancesModule(address(hook));
        amId = modules.addModule(address(am), '{"name":"Alliances"}');
        ally1 = new MockRewardToken();
        rival1 = new MockRewardToken();
        _allowQuote(address(ally1));
        _allowQuote(address(rival1));
    }

    function _cfg(uint16 capBps, address[] memory allies, address[] memory rivals) internal pure returns (bytes memory) {
        return abi.encode(AlliancesModule.Config(capBps, AMIN, RMIN, allies, rivals));
    }

    function _arr(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _launchAs(address who, bytes memory cfg) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Ally";
        a.symbol = "ALLY";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(amId);
        a.moduleConfigs = _oneCfg(cfg);
        uint256 fee = pad.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        t = HookTokenV2(pad.launch{value: fee}(a));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(am.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY);
        assertEq(am.conflictGroups(), ModuleCaps.GROUP_HOLDING_CAP);
        address[] memory none = new address[](0);
        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) five[i] = address(uint160(100 + i));
        vm.expectRevert();
        am.validateConfig(_cfg(9, none, none));
        vm.expectRevert();
        am.validateConfig(_cfg(5_001, none, none));
        vm.expectRevert();
        am.validateConfig(_cfg(0, five, none));
        vm.expectRevert();
        am.validateConfig(_cfg(0, none, five));
        vm.expectRevert(); // same token ally and rival
        am.validateConfig(_cfg(0, _arr(address(ally1)), _arr(address(ally1))));
        vm.expectRevert();
        am.validateConfig(abi.encode(AlliancesModule.Config(0, 0, RMIN, none, none)));
        am.validateConfig(_cfg(0, none, none));
        // a treaty token without code fails the launch, and so does any ERC-20 that is neither a v2 token nor
        // an allowed quote (M-3)
        _launchReverts(amId, _cfg(0, none, _arr(makeAddr("noCode"))));
        _launchReverts(amId, _cfg(0, none, _arr(address(new MockRewardToken()))));
        _launchReverts(amId, _cfg(0, _arr(address(new MockRewardToken())), none));
    }

    function test_launchRival_curveAndPool() public {
        HookTokenV2 t = _launch(_one(amId), _oneCfg(_cfg(0, new address[](0), _arr(address(rival1)))), 0);
        rival1.mint(bob, RMIN);
        rival1.mint(carol, RMIN - 1);
        _curveBuyReverts(bob, t, 1 ether);
        _curveBuy(carol, t, 1 ether);
        (address barred,) = am.standing(address(t), bob);
        assertEq(barred, address(rival1));
        // a holder who picks up rival tokens can still sell
        rival1.mint(carol, 1);
        uint256 bal = t.balanceOf(carol);
        vm.prank(carol);
        pad.sell(address(t), bal / 2, 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        _buyReverts(bob, t, 1 ether);
        uint256 got = _routerBuy(alice, t, 1 ether);
        _sendReverts(t, alice, bob, got);
        _send(t, alice, creator, got / 2); // creator exempt (no rival tokens anyway)
        _aggSwapRouterOnly(key, true, -int256(1 ether)); // rival set: direct PoolManager buys refused (claims guard)
        _routerSell(carol, t, t.balanceOf(carol));
    }

    function test_capWithLaunchAllyVisa() public {
        HookTokenV2 t = _launch(_one(amId), _oneCfg(_cfg(500, _arr(address(ally1)), new address[](0))), 0);
        _graduateCapped(t, 20_000_000 ether, 0);
        uint256 cap = SUPPLY * 500 / 10_000;
        _buyReverts(bob, t, 1_000 ether);
        ally1.mint(bob, AMIN);
        (, bool visa) = am.standing(address(t), bob);
        assertTrue(visa);
        vm.prank(bob);
        router.buy{value: 1_000 ether}(address(t), 1_000 ether, 0, address(0), block.timestamp, "");
        assertGt(t.balanceOf(bob), cap);
        // visa-less wallet can't take it over the cap
        _sendReverts(t, bob, carol, cap + 1);
        _send(t, bob, carol, cap);
    }

    function test_postLaunchRivalAndDrop() public {
        HookTokenV2 a = _launch(_one(amId), _oneCfg(_cfg(0, new address[](0), new address[](0))), 0);
        HookTokenV2 b = _launchAs(otherCreator, _cfg(0, new address[](0), new address[](0)));
        _curveBuy(bob, b, 1 ether); // bob holds B
        vm.expectRevert(AlliancesModule.NotCreator.selector);
        vm.prank(alice);
        am.proposeTreaty(address(a), address(b), 2);
        address junk = address(new MockRewardToken());
        vm.expectRevert(AlliancesModule.BadTreaty.selector); // only v2 tokens / allowed quotes after launch
        vm.prank(creator);
        am.proposeTreaty(address(a), junk, 2);
        vm.expectRevert(AlliancesModule.BadTreaty.selector); // alliances only with v2 tokens
        vm.prank(creator);
        am.proposeTreaty(address(a), address(rival1), 1);
        vm.prank(creator);
        am.proposeTreaty(address(a), address(b), 2);
        _curveBuyReverts(bob, a, 1 ether);
        vm.prank(creator);
        am.dropTreaty(address(a), address(b));
        _curveBuy(bob, a, 1 ether);
        vm.expectRevert(AlliancesModule.NoTreaty.selector);
        vm.prank(creator);
        am.dropTreaty(address(a), address(b));
    }

    function test_allianceNeedsAcceptance_mutualVisas_breakBothWays() public {
        HookTokenV2 a = _launch(_one(amId), _oneCfg(_cfg(500, new address[](0), new address[](0))), 0);
        HookTokenV2 b = _launchAs(otherCreator, _cfg(500, new address[](0), new address[](0)));
        vm.prank(creator);
        am.proposeTreaty(address(a), address(b), 1);
        assertTrue(am.proposed(address(a), address(b)));
        (address[] memory allies,,,,) = am.treaties(address(a));
        assertEq(allies.length, 0, "not before acceptance");
        vm.expectRevert(AlliancesModule.NotCreator.selector);
        vm.prank(creator);
        am.acceptAlliance(address(b), address(a));
        vm.prank(otherCreator);
        am.acceptAlliance(address(b), address(a));
        (allies,,,,) = am.treaties(address(a));
        assertEq(allies[0], address(b));
        (allies,,,,) = am.treaties(address(b));
        assertEq(allies[0], address(a));
        // a holder of B (>= allyMin) skips A's cap on the curve
        _curveBuy(bob, b, 1 ether);
        assertGe(b.balanceOf(bob), AMIN);
        uint256 big = _target(a) / 2; // well over 5% of supply
        _curveBuyReverts(carol, a, big);
        _curveBuy(bob, a, big);
        assertGt(a.balanceOf(bob), SUPPLY * 500 / 10_000);
        // B's creator breaks it: gone both ways
        vm.prank(otherCreator);
        am.dropTreaty(address(b), address(a));
        (allies,,,,) = am.treaties(address(a));
        assertEq(allies.length, 0);
        (allies,,,,) = am.treaties(address(b));
        assertEq(allies.length, 0);
        _curveBuyReverts(bob, a, 1 ether); // over the cap, no visa any more
    }

    function test_limitsOfFour_andGasWithEightReads() public {
        address[] memory allies = new address[](4);
        address[] memory rivals = new address[](4);
        for (uint256 i; i < 4; ++i) {
            allies[i] = address(new MockRewardToken());
            rivals[i] = address(new MockRewardToken());
            _allowQuote(allies[i]);
            _allowQuote(rivals[i]);
        }
        HookTokenV2 t = _launch(_one(amId), _oneCfg(_cfg(500, allies, rivals)), 0);
        HookTokenV2 b = _launchAs(otherCreator, _cfg(0, new address[](0), new address[](0)));
        vm.expectRevert(AlliancesModule.TooManyTreaties.selector);
        vm.prank(creator);
        am.proposeTreaty(address(t), address(b), 2);
        vm.expectRevert(AlliancesModule.TooManyTreaties.selector);
        vm.prank(creator);
        am.proposeTreaty(address(t), address(b), 1);
        _graduateCapped(t, 20_000_000 ether, 0);
        // visa from the LAST ally: worst case, 4 rival reads + 4 ally reads in one callback
        MockRewardToken(allies[3]).mint(bob, AMIN);
        vm.prank(bob);
        router.buy{value: 1_000 ether}(address(t), 1_000 ether, 0, address(0), block.timestamp, "");
        uint256 cap = SUPPLY * 500 / 10_000;
        assertGt(t.balanceOf(bob), cap);
        MockRewardToken(allies[3]).mint(carol, AMIN);
        uint256 g = gasleft();
        _send(t, bob, carol, cap + 1);
        uint256 used = g - gasleft();
        assertLt(used, 200_000, "whole transfer incl. 8 foreign reads stays under one module budget");
    }

    function testFuzz_rivalThreshold(uint256 held) public {
        held = bound(held, 0, 2 * RMIN);
        HookTokenV2 t = _launch(_one(amId), _oneCfg(_cfg(0, new address[](0), _arr(address(rival1)))), 0);
        rival1.mint(carol, held);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        if (held >= RMIN) vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);
    }
}
