// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BuyerRewardsModule} from "../../contracts/v2/modules/BuyerRewardsModule.sol";
import {NewModulesBase, MockRewardToken} from "./NewModulesBase.t.sol";

contract BuyerRewardsModuleTest is NewModulesBase {
    BuyerRewardsModule br;
    uint32 brId;
    HookTokenV2 t;
    PoolKey key;
    MockRewardToken rwd;

    uint128 constant REWARD = 10 ether;

    function setUp() public override {
        super.setUp();
        br = new BuyerRewardsModule(address(hook));
        brId = modules.addModule(address(br), '{"name":"Buyer rewards"}');
        rwd = new MockRewardToken();
        (t, key) = _launchOne(brId, _cfg(1 ether, 2));
        rwd.mint(creator, 1000 ether);
        vm.startPrank(creator);
        rwd.approve(address(br), type(uint256).max);
        br.fund(address(t), 35 ether); // three and a half rewards
        vm.stopPrank();
    }

    function _cfg(uint128 minBuy, uint16 maxPerWallet) internal view returns (bytes memory) {
        return abi.encode(BuyerRewardsModule.Config(address(rwd), REWARD, minBuy, maxPerWallet, 0));
    }

    function _owed(address w) internal view returns (uint256 o) {
        (o,,,) = br.owedTo(address(t), w);
    }

    function test_capabilities() public view {
        assertEq(br.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER);
        assertEq(br.conflictGroups(), 0);
    }

    function test_rewardsQualifyingRouterBuys() public {
        _routerBuy(alice, t, 1 ether);
        assertEq(_owed(alice), REWARD);
        _routerBuy(alice, t, 0.99 ether); // under the minimum
        _routerBuy(creator, t, 5 ether); // the creator doesn't earn from their own vault
        agg.swap(key, true, -int256(5 ether)); // buyer unknown
        assertEq(_owed(alice), REWARD);
        assertEq(_owed(creator), 0);
        _routerBuy(alice, t, 2 ether);
        _routerBuy(alice, t, 2 ether); // max 2 rewarded buys per wallet
        assertEq(_owed(alice), 2 * REWARD);
        (,, uint256 owed, uint256 free,,) = br.vault(address(t));
        assertEq(owed, 20 ether);
        assertEq(free, 15 ether);
    }

    function test_dryVaultStopsRewardsNeverBuys() public {
        vm.deal(makeAddr("dave"), 10 ether);
        vm.deal(makeAddr("erin"), 10 ether);
        _routerBuy(alice, t, 1 ether);
        _routerBuy(bob, t, 1 ether);
        _routerBuy(carol, t, 1 ether);
        _routerBuy(makeAddr("dave"), t, 1 ether); // 5 left: not enough for a reward, buy still goes through
        assertEq(_owed(makeAddr("dave")), 0);
        (,, uint256 owed, uint256 free,,) = br.vault(address(t));
        assertEq(owed, 30 ether);
        assertEq(free, 5 ether);
        // top-up by anyone restarts the rewards
        rwd.mint(bob, 10 ether);
        vm.startPrank(bob);
        rwd.approve(address(br), 10 ether);
        br.fund(address(t), 10 ether);
        vm.stopPrank();
        _routerBuy(makeAddr("erin"), t, 1 ether);
        assertEq(_owed(makeAddr("erin")), REWARD);
    }

    function test_claimAndWithdraw() public {
        _routerBuy(alice, t, 1 ether);
        vm.prank(alice);
        uint256 got = br.claim(address(t), alice);
        assertEq(got, REWARD);
        assertEq(rwd.balanceOf(alice), REWARD);
        vm.prank(alice);
        vm.expectRevert(BuyerRewardsModule.NothingOwed.selector);
        br.claim(address(t), alice);

        _routerBuy(bob, t, 1 ether); // bob is owed 10 of the 25 left
        vm.prank(alice);
        vm.expectRevert(BuyerRewardsModule.NotCreator.selector);
        br.withdraw(address(t), 1, alice);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BuyerRewardsModule.MoreThanFree.selector, 15 ether));
        br.withdraw(address(t), 15 ether + 1, creator);
        vm.prank(creator);
        br.withdraw(address(t), 15 ether, creator);
        vm.prank(bob);
        br.claim(address(t), bob); // what was earned is still there
        assertEq(rwd.balanceOf(bob), REWARD);
        assertEq(rwd.balanceOf(address(br)), 0);
    }

    /// Curve buys earn too (the buyer is always known on the curve).
    function test_curveBuysEarn() public {
        HookTokenV2 t2 = _launch(_one(brId), _oneCfg(_cfg(1 ether, 0)), 0);
        vm.prank(creator);
        br.fund(address(t2), 20 ether);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t2), 0);
        vm.prank(bob);
        pad.buy{value: 0.5 ether}(address(t2), 0); // under the minimum
        (uint256 oa,,,) = br.owedTo(address(t2), alice);
        (uint256 ob,,,) = br.owedTo(address(t2), bob);
        assertEq(oa, REWARD);
        assertEq(ob, 0);
        vm.prank(alice);
        br.claim(address(t2), alice);
        assertEq(rwd.balanceOf(alice), REWARD);
    }

    /// Audit L-1: buy-and-dump loops forfeit locked rewards; holders keep them after the lock.
    function test_lockForfeitsOnSellAndSend() public {
        HookTokenV2 t2 = _launch(_one(brId), _oneCfg(abi.encode(BuyerRewardsModule.Config(address(rwd), REWARD, 1 ether, 0, 1 days))), 0);
        vm.prank(creator);
        br.fund(address(t2), 100 ether);
        // alice buys then sells part on the curve within the lock: reward forfeited
        vm.startPrank(alice);
        pad.buy{value: 1 ether}(address(t2), 0);
        (uint256 o, , uint256 locked,) = br.owedTo(address(t2), alice);
        assertEq(o, 0);
        assertEq(locked, REWARD);
        t2.approve(address(pad), type(uint256).max);
        pad.sell(address(t2), t2.balanceOf(alice) / 10, 0);
        vm.stopPrank();
        (o, , locked,) = br.owedTo(address(t2), alice);
        assertEq(o + locked, 0);
        (,, uint256 owed, uint256 free,,) = br.vault(address(t2));
        assertEq(owed, 0);
        assertEq(free, 100 ether);
        // bob buys and holds past the lock: reward unlocks, a later sell doesn't take it back
        vm.prank(bob);
        pad.buy{value: 1 ether}(address(t2), 0);
        vm.warp(block.timestamp + 1 days);
        (o, , locked,) = br.owedTo(address(t2), bob);
        assertEq(o, REWARD);
        assertEq(locked, 0);
        vm.startPrank(bob);
        t2.approve(address(pad), type(uint256).max);
        pad.sell(address(t2), t2.balanceOf(bob) / 10, 0);
        assertEq(br.claim(address(t2), bob), REWARD);
        vm.stopPrank();
    }

    /// Audit L-1: counters never revert a buy (uint16 rewardedBuys saturates).
    function test_noCounterOverflowReverts() public {
        vm.expectRevert();
        br.validateConfig(abi.encode(BuyerRewardsModule.Config(address(rwd), REWARD, 1, 0, 31 days)));
    }

    function test_configBounds() public {
        vm.expectRevert();
        br.validateConfig(abi.encode(BuyerRewardsModule.Config(address(0), REWARD, 1, 0, 0)));
        vm.expectRevert();
        br.validateConfig(abi.encode(BuyerRewardsModule.Config(alice, REWARD, 1, 0, 0))); // not a contract
        vm.expectRevert();
        br.validateConfig(abi.encode(BuyerRewardsModule.Config(address(rwd), 0, 1, 0, 0)));
        vm.expectRevert();
        br.validateConfig(abi.encode(BuyerRewardsModule.Config(address(rwd), REWARD, 0, 0, 0)));
        br.validateConfig(abi.encode(BuyerRewardsModule.Config(address(rwd), REWARD, 1, 0, 0)));
    }

    function test_unknownToken() public {
        vm.expectRevert(BuyerRewardsModule.UnknownToken.selector);
        br.fund(address(0xdead), 1);
    }
}
