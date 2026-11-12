// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HolderDividendsModule} from "../../contracts/v2/modules/HolderDividendsModule.sol";
import {V2Base} from "./V2Base.t.sol";

/// Holds tokens but refuses AVAX (a vault or bridge that can't receive dividends).
contract NoAvax {
    receive() external payable {
        revert("no");
    }
}

contract HolderDividendsModuleTest is V2Base {
    HolderDividendsModule div;
    uint32 divId;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        div = new HolderDividendsModule(address(hook));
        divId = modules.addModule(address(div), '{"name":"Holder dividends"}');
        vm.txGasPrice(block.basefee);
    }

    function _cfg(uint16 bps) internal pure returns (bytes memory) {
        return abi.encode(HolderDividendsModule.Config(bps));
    }

    function _launchDiv(uint16 bps) internal returns (HookTokenV2 t) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = divId;
        cfgs[0] = _cfg(bps);
        t = _launch(ids, cfgs, 0);
    }

    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
    }

    function _holders(address a, address b) internal pure returns (address[] memory h) {
        h = new address[](2);
        (h[0], h[1]) = (a, b);
    }

    function test_configBounds() public {
        vm.expectRevert();
        div.validateConfig(_cfg(49));
        vm.expectRevert();
        div.validateConfig(_cfg(1_001));
        div.validateConfig(_cfg(50));
        div.validateConfig(_cfg(1_000));
    }

    /// Curve buys pay the share; holders earn pro-rata to their balances, the curve itself earns nothing.
    function test_curveDividendsProRata() public {
        HookTokenV2 t = _launchDiv(500);
        _curveBuy(alice, t, 1 ether);
        _curveBuy(bob, t, 1 ether);
        div.reconcile();
        HolderDividendsModule.Stats memory s = div.stats(address(t));
        assertEq(s.totalShares, t.balanceOf(alice) + t.balanceOf(bob), "shares = holder balances");
        assertEq(div.sharesOf(address(t), address(pad)), 0, "curve holds no shares");
        // Alice's buy was folded at her balance alone (+ carry), Bob's at both: alice > bob.
        uint256 pa = div.pending(address(t), alice);
        uint256 pb = div.pending(address(t), bob);
        assertGt(pa, pb);
        assertApproxEqAbs(pa + pb, s.distributed, 2, "everything distributed is owed");
        assertApproxEqAbs(s.distributed, 0.1 ether, 0.001 ether, "5% of 2 AVAX");
    }

    /// One transaction pays every listed holder to their wallet, minus the keeper's flat gas fee.
    function test_distributePushesToWallets() public {
        HookTokenV2 t = _launchDiv(1_000);
        _curveBuy(alice, t, 5 ether);
        _curveBuy(bob, t, 5 ether);
        _curveBuy(carol, t, 2 ether); // alice and bob earn from it (a buyer never earns from their own buy)
        div.reconcile();
        (uint256 perRecipient, uint256 perBatch,) = div.keeperFee(address(t));
        uint256 fee = perRecipient + perBatch / 2; // two holders share the batch's own gas
        uint256 pa = div.pending(address(t), alice);
        uint256 pb = div.pending(address(t), bob);
        uint256 a0 = alice.balance;
        uint256 b0 = bob.balance;
        uint256 g = gasleft();
        vm.prank(keeper);
        (uint256 paid, uint256 count) = div.distribute(address(t), _holders(alice, bob));
        uint256 used = g - gasleft();
        emit log_named_uint("gas for a 2-holder batch", used);
        assertLt(used, 2 * div.PAY_GAS() + div.BATCH_GAS(), "the fee covers a small batch too");
        assertEq(count, 2);
        assertEq(alice.balance - a0, pa - fee);
        assertEq(bob.balance - b0, pb - fee);
        assertEq(paid, pa + pb - 2 * fee);
        assertEq(keeper.balance, 2 * fee, "keeper paid from the amounts");
        assertEq(div.pending(address(t), alice), 0);
        assertGe(address(div).balance, div.cash(address(0)), "cash backed");
    }

    function test_belowMinimumWaits() public {
        HookTokenV2 t = _launchDiv(50);
        _curveBuy(alice, t, 0.001 ether);
        _curveBuy(bob, t, 0.001 ether);
        div.reconcile();
        uint256 pa = div.pending(address(t), alice);
        (,, uint256 minPayout) = div.keeperFee(address(t));
        assertLt(pa, minPayout);
        vm.prank(keeper);
        (, uint256 count) = div.distribute(address(t), _holders(alice, bob));
        assertEq(count, 0);
        assertEq(div.pending(address(t), alice), pa, "still owed");
        // A holder can always claim in full, without a fee.
        uint256 a0 = alice.balance;
        vm.prank(alice);
        div.claim(address(t));
        assertEq(alice.balance - a0, pa);
    }

    /// Pool trades (both sides, any route) pay too; transfers move future dividends with the tokens.
    function test_poolTradesAndTransfers() public {
        HookTokenV2 t = _launchDiv(300);
        _graduate(t);
        assertEq(div.sharesOf(address(t), address(PM)), 0, "the pool earns nothing");
        uint256 got = _routerBuy(alice, t, 10 ether);
        div.reconcile();
        HolderDividendsModule.Stats memory s0 = div.stats(address(t));
        uint256 sellOut = _routerSell(alice, t, got / 2);
        assertGt(sellOut, 0);
        div.reconcile();
        HolderDividendsModule.Stats memory s1 = div.stats(address(t));
        assertGt(s1.distributed, s0.distributed, "sells pay too");

        // Alice sends everything to carol: carol earns from now on, alice keeps what she had earned.
        uint256 earned = div.pending(address(t), alice);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        t.transfer(carol, bal);
        assertEq(div.sharesOf(address(t), alice), 0);
        assertEq(div.sharesOf(address(t), carol), bal);
        _routerBuy(bob, t, 10 ether);
        div.reconcile();
        assertEq(div.pending(address(t), alice), earned, "alice's share frozen");
        assertGt(div.pending(address(t), carol), 0, "carol earns");
        assertEq(div.stats(address(t)).totalShares, _sumShares(t), "shares track balances");
    }

    function _sumShares(HookTokenV2 t) internal view returns (uint256 sum) {
        address[4] memory who = [alice, bob, carol, creator];
        for (uint256 i; i < who.length; ++i) sum += div.sharesOf(address(t), who[i]);
        for (uint256 i; i < 16; ++i) sum += div.sharesOf(address(t), address(uint160(0xB0B000 + i)));
    }

    /// A holder that refuses AVAX is skipped (the batch goes on) and can be recycled to everyone 90 days after
    /// that failed send.
    function test_refusingHolderSkippedThenRecycled() public {
        HookTokenV2 t = _launchDiv(1_000);
        NoAvax vault = new NoAvax();
        _graduate(t); // tokens can't move between wallets on the curve
        _routerBuy(alice, t, 30 ether); // the vault must be owed past the minimum: only a real send can fail
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        t.transfer(address(vault), half);
        _routerBuy(bob, t, 30 ether); // enough for bob to clear the minimum from carol's buy alone
        _routerBuy(carol, t, 50 ether);
        div.reconcile();
        uint256 owedVault = div.pending(address(t), address(vault));
        assertGt(owedVault, 0);
        vm.prank(keeper);
        (, uint256 count) = div.distribute(address(t), _holders(address(vault), bob));
        assertEq(count, 1, "bob paid, vault skipped");
        assertEq(div.pending(address(t), address(vault)), owedVault, "vault still owed");
        assertEq(div.failedAt(div.poolOf(address(t)), address(vault)), block.timestamp, "the failed send starts the clock");

        address[] memory one = new address[](1);
        one[0] = address(vault);
        div.recycle(address(t), one);
        assertEq(div.pending(address(t), address(vault)), owedVault, "not before 90 days");
        vm.warp(block.timestamp + 91 days);
        uint256 a0 = div.pending(address(t), alice);
        div.recycle(address(t), one);
        assertLt(div.pending(address(t), address(vault)), owedVault, "recycled");
        assertGt(div.pending(address(t), alice), a0, "back to the holders");
    }

    /// Gas per paid holder stays under PAY_GAS, so the keeper fee covers it.
    function test_batchGasPerHolder() public {
        HookTokenV2 t = _launchDiv(1_000);
        uint256 n = 200;
        address[] memory hs = new address[](n);
        for (uint256 i; i < n; ++i) {
            hs[i] = address(uint160(0xD1D000 + i));
            vm.deal(hs[i], 1 ether);
            _curveBuy(hs[i], t, 0.05 ether);
        }
        _graduate(t);
        for (uint256 i; i < 5; ++i) _routerBuy(alice, t, 50 ether); // enough volume for every holder to clear the minimum
        div.reconcile();
        uint256 g = gasleft();
        vm.prank(keeper);
        (, uint256 count) = div.distribute(address(t), hs);
        uint256 used = g - gasleft();
        assertEq(count, n);
        emit log_named_uint("gas per paid holder", used / n);
        assertLt(used, n * div.PAY_GAS() + div.BATCH_GAS(), "the fee covers the batch");
    }

    function test_batchTooLarge() public {
        HookTokenV2 t = _launchDiv(100);
        address[] memory hs = new address[](1_001);
        vm.expectRevert(HolderDividendsModule.BatchTooLarge.selector);
        div.distribute(address(t), hs);
    }
}
