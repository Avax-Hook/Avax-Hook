// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {QuoteRegistry} from "../../contracts/QuoteRegistry.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {PolarityModuleV2} from "../../contracts/v2/modules/PolarityModuleV2.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract PolarityModuleV2Test is NewModulesBase {
    PolarityModuleV2 pol;
    uint32 polId;
    uint16 constant FEE = 100; // 1%

    function setUp() public override {
        super.setUp();
        pol = new PolarityModuleV2(address(hook), _assets());
        polId = modules.addModule(address(pol), '{"name":"Polarity"}');
        _mockAvaxUsd(20e18);
    }

    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd; // signed feed: not allowed

    /// The live QuoteRegistry quotes whose feed is a Chainlink aggregator (checked on the fork).
    function _assets() internal pure returns (address[] memory a) {
        a = new address[](3);
        (a[0], a[1], a[2]) = (address(0), USDC, USDT);
    }

    function _cfg(uint8 side, uint8 lev, uint16 fee, address partner) internal pure returns (bytes memory) {
        return abi.encode(PolarityModuleV2.Config(address(0), side, lev, fee, partner));
    }

    function _launchAs(address who, bytes memory cfg) internal returns (HookTokenV2 t) {
        return _launchAs(who, cfg, false);
    }

    function _launchReverts(address who, bytes memory cfg) internal {
        _launchAs(who, cfg, true);
    }

    function _launchAs(address who, bytes memory cfg, bool reverts) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Side";
        a.symbol = "SIDE";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(polId);
        a.moduleConfigs = _oneCfg(cfg);
        uint256 fee = pad.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        if (reverts) vm.expectRevert();
        t = HookTokenV2(pad.launch{value: fee}(a));
    }

    function _pair(uint8 lev) internal returns (HookTokenV2 bull, HookTokenV2 bear) {
        bull = _launchAs(creator, _cfg(0, lev, FEE, address(0)));
        bear = _launchAs(creator, _cfg(1, lev, FEE, address(bull)));
    }

    function _pots(HookTokenV2 t) internal view returns (uint256 b, uint256 s, uint256 pLast, bool paired) {
        (PolarityModuleV2.Pair memory p,,) = pol.pairOf(address(t));
        return (p.potBull, p.potBear, p.pLast, p.paired);
    }

    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
    }

    function test_capabilitiesAndConfigBounds() public {
        assertEq(pol.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        assertEq(pol.conflictGroups(), 0);
        pol.validateConfig(_cfg(0, 10, 300, address(0)));
        pol.validateConfig(_cfg(1, 50, 1, address(1234)));
        bytes[6] memory bad = [
            _cfg(2, 20, FEE, address(0)), // side
            _cfg(0, 9, FEE, address(0)), // leverage
            _cfg(0, 51, FEE, address(0)),
            _cfg(0, 20, 0, address(0)), // fee
            _cfg(0, 20, 301, address(0)),
            _cfg(0, 20, FEE, address(1234)) // BULL with a partner
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert();
            pol.validateConfig(bad[i]);
        }
        vm.expectRevert();
        pol.validateConfig(_cfg(1, 20, FEE, address(0))); // BEAR without partner
        vm.expectRevert(); // asset without a USD feed
        pol.validateConfig(abi.encode(PolarityModuleV2.Config(address(0xBEEF), 0, 20, FEE, address(0))));
        vm.expectRevert(); // a signed-feed quote is not on the allowlist
        pol.validateConfig(abi.encode(PolarityModuleV2.Config(JOE, 0, 20, FEE, address(0))));
        pol.validateConfig(abi.encode(PolarityModuleV2.Config(USDC, 0, 20, FEE, address(0))));
        assertEq(pol.assets().length, 3);
        assertTrue(pol.allowedAsset(USDT));
        // constructor: no empty or duplicate allowlist
        vm.expectRevert();
        new PolarityModuleV2(address(hook), new address[](0));
        address[] memory dup = new address[](2);
        vm.expectRevert();
        new PolarityModuleV2(address(hook), dup);
        vm.expectRevert(PolarityModuleV2.NoRescue.selector);
        pol.rescue(address(0));
    }

    function test_unpairedPotJustGrows() public {
        HookTokenV2 bull = _launchAs(creator, _cfg(0, 20, FEE, address(0)));
        _curveBuy(alice, bull, 10 ether);
        (uint256 b, uint256 s, uint256 pLast, bool paired) = _pots(bull);
        assertEq(b, 0.1 ether, "1% of the buy");
        assertEq(s, 0);
        assertEq(pLast, 0);
        assertFalse(paired);
        assertEq(hook.claimable(address(pol), NATIVE), 0.1 ether);
        _mockAvaxUsd(40e18); // no partner: nothing moves
        _curveBuy(bob, bull, 10 ether);
        (b,,,) = _pots(bull);
        assertEq(b, 0.2 ether);
    }

    function test_pairingRules() public {
        HookTokenV2 bull = _launchAs(creator, _cfg(0, 20, FEE, address(0)));
        // a different creator can't complete someone's pair
        _launchReverts(alice, _cfg(1, 20, FEE, address(bull)));
        // leverage must match
        _launchReverts(creator, _cfg(1, 30, FEE, address(bull)));
        // partner must be a BULL of this module
        _launchReverts(creator, _cfg(1, 20, FEE, address(0xBEEF)));
        HookTokenV2 bear = _launchAs(creator, _cfg(1, 20, 50, address(bull)));
        (PolarityModuleV2.Pair memory p, uint8 side, uint16 fee) = pol.pairOf(address(bear));
        assertTrue(p.paired);
        assertEq(p.bullToken, address(bull));
        assertEq(p.bearToken, address(bear));
        assertEq(p.pLast, 20e18, "price at pairing");
        assertEq(side, 1);
        assertEq(fee, 50, "each side keeps its own fee");
        // one BEAR per BULL
        _launchReverts(creator, _cfg(1, 20, FEE, address(bull)));
        // a BEAR can't be anyone's partner
        _launchReverts(creator, _cfg(1, 20, FEE, address(bear)));
    }

    // r = 5% at 2x: f = 10% of the SMALLER pot (BULL's 0.1) moves from BEAR to BULL, then the trade's fee
    function test_priceUpShiftsBearToBull() public {
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(20);
        _curveBuy(alice, bull, 10 ether);
        _curveBuy(bob, bear, 20 ether);
        (uint256 b0, uint256 s0,,) = _pots(bull);
        assertEq(b0, 0.1 ether);
        assertEq(s0, 0.2 ether);
        _mockAvaxUsd(21e18);
        (uint256 pb, uint256 ps, uint256 price) = pol.previewPots(address(bull));
        assertEq(price, 21e18);
        assertEq(pb, b0 + b0 / 10, "10% of min(pots)");
        assertEq(ps, s0 - b0 / 10);
        _curveBuy(carol, bear, 1 ether);
        (uint256 b1, uint256 s1, uint256 pLast,) = _pots(bull);
        assertEq(b1, b0 + b0 / 10, "BULL won 10% of the smaller pot");
        assertEq(s1, s0 - b0 / 10 + 0.01 ether, "BEAR lost it, then got this buy's fee");
        assertEq(pLast, 21e18);
        assertEq(b1 + s1, hook.claimable(address(pol), NATIVE), "pots == module claims");
    }

    function test_priceDownShiftsBullToBear_cappedAt50() public {
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(50); // 5x
        _curveBuy(alice, bull, 10 ether);
        _curveBuy(bob, bear, 10 ether);
        _mockAvaxUsd(16e18); // -20% at 5x = 100% -> capped at 50%
        pol.sync(address(bear));
        (uint256 b, uint256 s, uint256 pLast,) = _pots(bull);
        assertEq(b, 0.05 ether);
        assertEq(s, 0.15 ether);
        assertEq(pLast, 16e18);
    }

    function test_underOneBpAndStaleFeedSkip() public {
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(20);
        _curveBuy(alice, bull, 10 ether);
        _curveBuy(bob, bear, 10 ether);
        _mockAvaxUsd(20.0019e18); // +0.95 bp
        pol.sync(address(bull));
        (uint256 b, uint256 s, uint256 pLast,) = _pots(bull);
        assertEq(b, 0.1 ether);
        assertEq(s, 0.1 ether);
        assertEq(pLast, 20e18, "skipped, pLast kept");
        // the feed reverts (stale): trades go through, nothing moves
        vm.mockCallRevert(
            address(LIVE_QUOTES), abi.encodeWithSelector(QuoteRegistry.usdPrice.selector, address(0)), "StalePrice"
        );
        _curveBuy(carol, bear, 10 ether);
        uint256 half = bear.balanceOf(carol) / 2;
        vm.prank(carol);
        pad.sell(address(bear), half, 0);
        (b, s, pLast,) = _pots(bull);
        assertEq(b, 0.1 ether);
        assertGt(s, 0.2 ether, "fees still fill the pot");
        assertEq(pLast, 20e18);
        (,, uint256 price) = pol.previewPots(address(bull));
        assertEq(price, 0);
        // a malformed answer is ignored too
        vm.mockCall(address(LIVE_QUOTES), abi.encodeWithSelector(QuoteRegistry.usdPrice.selector, address(0)), hex"01");
        pol.sync(address(bull));
    }

    function test_poolPhaseFeesAndRedeem() public {
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(20);
        // redeem is closed on the curve (V2: the module's own isOpen check, before any token transfer)
        _curveBuy(alice, bull, 10 ether);
        vm.startPrank(alice);
        bull.approve(address(pol), type(uint256).max);
        vm.expectRevert(PolarityModuleV2.NotGraduated.selector);
        pol.redeem(address(bull), 1 ether, 0);
        vm.stopPrank();

        PoolKey memory key = _graduateN(bull, 20, 0);
        _curveBuy(bob, bear, 5 ether);
        (uint256 b0,,,) = _pots(bull);
        // pool fees: router buy, router sell, direct PoolManager swap all pay
        uint256 got = _routerBuy(carol, bull, 10 ether);
        (uint256 b1,,,) = _pots(bull);
        assertEq(b1 - b0, 0.1 ether, "router buy");
        uint256 out = _routerSell(carol, bull, got / 2);
        (uint256 b2,,,) = _pots(bull);
        assertApproxEqRel(b2 - b1, out / 99, 0.01e18, "router sell: 1% of the gross output");
        agg.swap(key, true, -int256(5 ether));
        (uint256 b3,,,) = _pots(bull);
        assertEq(b3 - b2, 0.05 ether, "direct swap");

        // price up: BULL wins part of BEAR's pot first, then redeem pays pro rata
        _mockAvaxUsd(22e18); // +10% at 2x: 20%
        uint256 amount = bull.balanceOf(alice) / 2;
        uint256 circ = pol.circulating(address(bull));
        uint256 preview = pol.previewRedeem(address(bull), amount);
        (uint256 pb,,) = pol.previewPots(address(bull));
        assertEq(preview, (amount * pb) / circ);
        uint256 bal = alice.balance;
        uint256 dead = bull.balanceOf(DEAD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PolarityModuleV2.Slippage.selector, preview, preview + 1));
        pol.redeem(address(bull), amount, preview + 1);
        vm.prank(alice);
        uint256 paid = pol.redeem(address(bull), amount, preview);
        assertEq(paid, preview);
        assertEq(alice.balance - bal, paid, "paid in native AVAX");
        assertEq(bull.balanceOf(DEAD) - dead, amount, "tokens burned to dEaD");
        (uint256 b4, uint256 s4,,) = _pots(bull);
        assertEq(b4, pb - paid);
        // solvency: pots == module claims + cash
        assertEq(b4 + s4, hook.claimable(address(pol), NATIVE) + pol.cash(address(0)));
        assertEq(address(pol).balance, pol.cash(address(0)));
        // the floor per token is unchanged for the rest
        assertApproxEqRel((b4 * 1e18) / pol.circulating(address(bull)), (pb * 1e18) / circ, 1e9);
        // second redeem pays from cash
        vm.prank(alice);
        pol.redeem(address(bull), amount / 2, 0);
        (b4, s4,,) = _pots(bull);
        assertEq(b4 + s4, hook.claimable(address(pol), NATIVE) + pol.cash(address(0)));
        vm.expectRevert(PolarityModuleV2.ZeroAmount.selector);
        pol.redeem(address(bull), 0, 0);
        vm.expectRevert(PolarityModuleV2.NotRegistered.selector);
        pol.redeem(address(0xBEEF), 1, 0);
    }

    function test_strayAvaxRefused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(pol).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /// Any price path: a rebalance never moves more than half the losing pot and never changes the total.
    function testFuzz_shiftBounded(uint64 p1, uint8 lev) public {
        lev = uint8(bound(lev, 10, 50));
        uint256 price = bound(uint256(p1), 1e15, 1e24);
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(lev);
        _curveBuy(alice, bull, 10 ether);
        _curveBuy(bob, bear, 10 ether);
        (uint256 b0, uint256 s0,,) = _pots(bull);
        _mockAvaxUsd(price);
        pol.sync(address(bull));
        (uint256 b1, uint256 s1,,) = _pots(bull);
        assertEq(b0 + s0, b1 + s1);
        assertGe(b1, b0 / 2);
        assertGe(s1, s0 / 2);
    }
}
