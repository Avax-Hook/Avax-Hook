// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLensV2} from "../../contracts/v2/HookLensV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {PartnerFeeModule} from "../../contracts/v2/modules/PartnerFeeModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract PartnerFeeModuleTest is NewModulesBase {
    PartnerFeeModule pf;
    uint32 pfId;
    address safe = makeAddr("safe");
    address payout = makeAddr("berryTreasury");
    bytes32 constant BERRY = keccak256("berry");
    uint16 constant FEE = 20; // 0.2%

    function setUp() public override {
        super.setUp();
        pf = new PartnerFeeModule(address(hook), safe);
        pfId = modules.addModule(address(pf), '{"name":"Partner fee","hidden":true}');
        vm.prank(safe);
        pf.registerPartner(BERRY, payout, 100);
    }

    function _cfg(uint16 bps) internal pure returns (bytes memory) {
        return abi.encode(PartnerFeeModule.Config(BERRY, bps));
    }

    function test_capabilitiesAndViews() public {
        assertEq(pf.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        assertEq(pf.conflictGroups(), 0);
        (address p, uint16 max, bool active) = pf.partners(BERRY);
        assertEq(p, payout);
        assertEq(max, 100);
        assertTrue(active);
        HookTokenV2 t = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        (bytes32 id, uint16 bps) = pf.partnerOf(address(t));
        assertEq(id, BERRY);
        assertEq(bps, FEE);
        (id, bps) = pf.partnerOf(address(0xBEEF));
        assertEq(id, bytes32(0));
        assertEq(bps, 0);
    }

    // 1. curve buys and sells
    function test_curveFee() public {
        HookTokenV2 t = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        assertEq(hook.claimable(payout, NATIVE), 0.02 ether, "0.2% of the buy");
        uint256 bal = t.balanceOf(alice);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        pad.sell(address(t), bal, 0);
        uint256 out = alice.balance - b0;
        uint256 gross = (out * 10_000) / (10_000 - 30 - 50 - FEE);
        assertApproxEqAbs(hook.claimable(payout, NATIVE) - 0.02 ether, (gross * FEE) / 10_000, 1e12, "0.2% of the sell");
    }

    // 2. pool swaps after graduation, through the router and a direct PoolManager swap; graduation mid-trade
    function test_poolFeeAndGraduation() public {
        HookTokenV2 t = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        uint256 target = uint256(pad.getLaunch(address(t)).target);
        // one buy larger than the curve: graduates mid-trade, the excess is refunded
        vm.deal(bob, target * 2);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        pad.buy{value: target * 2}(address(t), 0);
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        uint256 spent = b0 - bob.balance;
        // the capped last buy is grossed up from what the curve needs, so the fee is a hair under 0.2% of spent
        assertLe(hook.claimable(payout, NATIVE), (spent * FEE) / 10_000, "never above the share");
        assertApproxEqRel(hook.claimable(payout, NATIVE), (spent * FEE) / 10_000, 0.005e18, "fee on what was spent");

        uint256 c0 = hook.claimable(payout, NATIVE);
        uint256 got = _routerBuy(alice, t, 10 ether);
        assertEq(hook.claimable(payout, NATIVE) - c0, 0.02 ether, "router buy");
        c0 = hook.claimable(payout, NATIVE);
        uint256 out = _routerSell(alice, t, got);
        uint256 gross = (out * 10_000) / (10_000 - 30 - 50 - FEE);
        assertApproxEqAbs(hook.claimable(payout, NATIVE) - c0, (gross * FEE) / 10_000, 1e12, "router sell");
        PoolKey memory key = pad.poolKey(address(t));
        c0 = hook.claimable(payout, NATIVE);
        agg.swap(key, true, -int256(5 ether));
        assertEq(hook.claimable(payout, NATIVE) - c0, 0.01 ether, "direct PoolManager swap");
    }

    // 3. only the payout claims; after a payout change new fees go to the new address
    function test_claimAndPayoutChange() public {
        HookTokenV2 t = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        // someone else has nothing to claim
        vm.expectRevert();
        vm.prank(alice);
        hook.claim(NATIVE, alice);
        assertEq(hook.claimable(payout, NATIVE), 0.02 ether);

        address multisig = makeAddr("berryMultisig");
        vm.expectRevert(PartnerFeeModule.NotPayout.selector);
        vm.prank(alice);
        pf.setPartnerPayout(BERRY, alice);
        vm.prank(payout);
        pf.setPartnerPayout(BERRY, multisig);
        vm.expectRevert(PartnerFeeModule.NotPayout.selector);
        vm.prank(alice);
        pf.acceptPartnerPayout(BERRY);
        vm.prank(multisig);
        pf.acceptPartnerPayout(BERRY);
        (address p,,) = pf.partners(BERRY);
        assertEq(p, multisig);
        // the old payout can no longer move the payout
        vm.expectRevert(PartnerFeeModule.NotPayout.selector);
        vm.prank(payout);
        pf.setPartnerPayout(BERRY, payout);

        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        assertEq(hook.claimable(multisig, NATIVE), 0.02 ether, "new fees to the new payout");
        assertEq(hook.claimable(payout, NATIVE), 0.02 ether, "credited fees stay");
        vm.prank(payout);
        hook.claim(NATIVE, payout);
        assertEq(payout.balance, 0.02 ether);
        vm.prank(multisig);
        hook.claim(NATIVE, multisig);
        assertEq(multisig.balance, 0.02 ether);
    }

    function _launchReverts(bytes memory cfg) internal {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "King";
        a.symbol = "KING";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3_000});
        a.moduleIds = _one(pfId);
        a.moduleConfigs = _oneCfg(cfg);
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        vm.expectRevert();
        pad.launch{value: fee}(a);
    }

    // 4. unknown partner, inactive partner, share above its max: the launch reverts
    function test_launchReverts() public {
        uint32[] memory ids = _one(pfId);
        _launchReverts(abi.encode(PartnerFeeModule.Config(keccak256("nobody"), FEE)));
        _launchReverts(_cfg(101));
        _launchReverts(_cfg(0));
        vm.prank(safe);
        pf.registerPartner(BERRY, payout, 20);
        _launchReverts(_cfg(21));
        _launch(ids, _oneCfg(_cfg(20)), 50);

        HookTokenV2 live = _launch(ids, _oneCfg(_cfg(FEE)), 50);
        vm.prank(safe);
        pf.setPartnerActive(BERRY, false);
        _launchReverts(_cfg(FEE));
        // an existing token keeps paying the deactivated partner
        uint256 c0 = hook.claimable(payout, NATIVE);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(live), 0);
        assertEq(hook.claimable(payout, NATIVE) - c0, 0.002 ether);
    }

    function test_registryAdmin() public {
        vm.expectRevert();
        pf.registerPartner(keccak256("x"), alice, 50); // not the owner
        vm.startPrank(safe);
        vm.expectRevert();
        pf.registerPartner(keccak256("x"), alice, 101); // above the hard cap
        vm.expectRevert();
        pf.registerPartner(keccak256("x"), address(0), 50);
        vm.expectRevert();
        pf.registerPartner(BERRY, alice, 50); // the owner can't redirect a partner's payout
        vm.expectRevert(PartnerFeeModule.UnknownPartner.selector);
        pf.setPartnerActive(keccak256("x"), false);
        vm.stopPrank();
    }

    // 5. the creator's claimable is the same as without the partner (same creatorFeeBps)
    function test_creatorUntouched() public {
        HookTokenV2 a = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        HookTokenV2 b = _launch(new uint32[](0), new bytes[](0), 50);
        uint256 c0 = pad.claimable(creator, address(0));
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(a), 0);
        uint256 ca = pad.claimable(creator, address(0)) - c0;
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(b), 0);
        uint256 cb = pad.claimable(creator, address(0)) - c0 - ca;
        assertEq(ca, cb, "creator fee unchanged");
        assertEq(ca, 0.05 ether);
    }

    // 6. lens quotes match what the chain does
    function test_lensQuotes() public {
        HookTokenV2 t = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), 10 ether, alice);
        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        uint256 got = t.balanceOf(alice);
        assertEq(got, q.out, "lens = buy");
        assertEq(q.inCut, 0.02 ether, "partner cut in the quote");
        q = lens.quoteSell(address(t), got, alice);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        pad.sell(address(t), got, 0);
        assertEq(alice.balance - b0, q.out, "lens = sell");
    }

    // 7. fuzz: the partner never takes more than its share; total fees stay within creator + protocol + partner
    function testFuzz_feesBounded(uint96 amount) public {
        uint256 x = bound(uint256(amount), 1e9, 50 ether);
        HookTokenV2 t = _launch(_one(pfId), _oneCfg(_cfg(FEE)), 50);
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), x, alice);
        uint256 c0 = hook.claimable(payout, NATIVE);
        uint256 cr0 = pad.claimable(creator, address(0));
        vm.deal(alice, x);
        vm.prank(alice);
        pad.buy{value: x}(address(t), 0);
        uint256 partnerFee = hook.claimable(payout, NATIVE) - c0;
        uint256 creatorFee = pad.claimable(creator, address(0)) - cr0;
        assertLe(partnerFee, (x * FEE) / 10_000);
        assertLe(partnerFee + creatorFee, (x * (FEE + 50)) / 10_000);
        assertEq(q.inCut, partnerFee);
    }
}
