// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ReferralModule} from "../../contracts/v2/modules/ReferralModule.sol";
import {V1PortBase, SpoofSwapper} from "./V1PortBase.t.sol";

contract ReferralModuleTest is V1PortBase {
    HookTokenV2 t;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        // core creator fee 0, module fee 1% with a 0.5% referral (v1 creatorFeeBps 100 / referralBps 50)
        t = _launch(_ids1(referralId), _cfgs1(_referralCfg(100, 50)), 0);
        key = _graduate(t);
    }

    // v1 test_creatorFeeAndReferral
    function test_creatorFeeAndReferral() public {
        uint256 c0 = hook.claimable(creator, NATIVE); // the module's fee on the curve buys
        _routerBuyRef(bob, t, 10 ether, alice);
        assertEq(hook.claimable(alice, NATIVE), 0.05 ether); // referral comes out of the creator fee
        assertEq(hook.claimable(creator, NATIVE) - c0, 0.05 ether);
        uint256 out = _routerSell(bob, t, t.balanceOf(bob));
        // creator also earns 1% of the sell's AVAX output (before cuts: 0.3% protocol + 1%)
        assertApproxEqRel(hook.claimable(creator, NATIVE) - c0 - 0.05 ether, (out * 100) / 9_870, 0.001e18);
        assertGt(hook.claimable(hook.PROTOCOL(), NATIVE), 0.03 ether); // fixed 0.3% protocol fee
        assertEq(referral.ruleOf(_id(key)).totalReferral, 0.05 ether);
    }

    // Buyers pay the same with or without a referral link.
    function test_noExtraCostForReferredBuyer() public {
        HookTokenV2 t2 = _launch(_ids1(referralId), _cfgs1(_referralCfg(100, 50)), 0);
        _graduate(t2);
        uint256 c0 = hook.claimable(creator, NATIVE);
        assertEq(_routerBuyRef(bob, t, 10 ether, alice), _routerBuy(carol, t2, 10 ether));
        assertEq(hook.claimable(creator, NATIVE) - c0, 0.05 ether + 0.1 ether);
    }

    // L-2 / HK-7 PoC re-run: sticky first referrer, no second-wallet rebates, no loops, no self-referral.
    function test_L2_stickyReferral() public {
        _routerBuyRef(bob, t, 10 ether, alice);
        assertEq(referral.referrerOf(bob), alice);
        _routerBuyRef(bob, t, 10 ether, carol); // bob's second wallet
        assertEq(referral.referrerOf(bob), alice);
        assertEq(hook.claimable(alice, NATIVE), 0.1 ether);
        assertEq(hook.claimable(carol, NATIVE), 0);
        // a referrer can't be bound to someone the buyer referred (no A <-> B loop)
        _routerBuyRef(alice, t, 1 ether, bob);
        assertEq(referral.referrerOf(alice), address(0));
        // the buyer itself is never a referrer
        _routerBuyRef(carol, t, 1 ether, carol);
        assertEq(referral.referrerOf(carol), address(0));
        assertEq(hook.claimable(carol, NATIVE), 0);
    }

    function test_selfReferralThroughTxOrigin() public {
        address wallet2 = makeAddr("wallet2");
        vm.deal(wallet2, 10 ether);
        // wallet2 buys inside a transaction signed by bob, naming bob: tx.origin can't be the referrer
        vm.prank(wallet2, bob);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, bob, block.timestamp, "");
        assertEq(referral.referrerOf(wallet2), address(0));
        // once bound, a referrer that signs the buyer's transaction earns nothing on it
        _routerBuyRef(wallet2, t, 1 ether, alice);
        uint256 a0 = hook.claimable(alice, NATIVE);
        vm.prank(wallet2, alice);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp, "");
        assertEq(hook.claimable(alice, NATIVE), a0);
    }

    // Only the router names buyers and referrers: a direct PoolManager swap with router-shaped hookData
    // can't bind or pay a referrer.
    function test_spoofedReferrerIgnored() public {
        SpoofSwapper s = new SpoofSwapper(PM);
        vm.deal(address(s), 10 ether);
        uint256 c0 = hook.claimable(creator, NATIVE);
        s.buyAs(key, 1 ether, bob, alice);
        assertEq(referral.referrerOf(bob), address(0));
        assertEq(hook.claimable(alice, NATIVE), 0);
        assertEq(hook.claimable(creator, NATIVE) - c0, 0.01 ether);
    }

    // Core creator fee + module fee stay within v1's 10%.
    function test_totalCreatorFeeCapped() public {
        vm.expectRevert();
        this.launchExt(_ids1(referralId), _cfgs1(_referralCfg(200, 50)), 900);
        this.launchExt(_ids1(referralId), _cfgs1(_referralCfg(100, 50)), 900);
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs, uint16 fee) external returns (HookTokenV2) {
        return _launch(ids, cfgs, fee);
    }

    function test_configBounds() public {
        vm.expectRevert();
        referral.validateConfig(_referralCfg(0, 0));
        vm.expectRevert();
        referral.validateConfig(_referralCfg(100, 101)); // more than the fee it comes out of
        vm.expectRevert();
        referral.validateConfig(_referralCfg(1_000, 201));
        vm.expectRevert();
        referral.validateConfig(_referralCfg(1_001, 50));
        referral.validateConfig(_referralCfg(1_000, 200));
    }
}
