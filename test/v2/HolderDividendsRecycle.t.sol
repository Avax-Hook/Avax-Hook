// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HolderDividendsModule} from "../../contracts/v2/modules/HolderDividendsModule.sol";
import {V2Base} from "./V2Base.t.sol";

contract RefuseAvax {
    bool public refuse = true;

    function setRefuse(bool r) external {
        refuse = r;
    }

    function claim(HolderDividendsModule d, address t) external {
        d.claim(t);
    }

    receive() external payable {
        require(!refuse);
    }
}

/// Regression: `recycle` only takes dividends of holders whose payout actually failed (PayFailed) at least
/// RECYCLE_AFTER ago with no successful payout or claim since. A passive holder (never moves, never claims,
/// below the keeper's minimum) keeps everything.
contract HolderDividendsRecycleTest is V2Base {
    HolderDividendsModule div;
    uint32 divId;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        div = new HolderDividendsModule(address(hook));
        divId = modules.addModule(address(div), '{"name":"Holder dividends"}');
    }

    function _launchDiv() internal returns (HookTokenV2 t) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = divId;
        cfgs[0] = abi.encode(HolderDividendsModule.Config(1_000));
        t = _launch(ids, cfgs, 0);
        _graduate(t);
    }

    /// Moves time forward (reads the timestamp through the cheatcode: via-ir may cache block.timestamp).
    function _skip(uint256 d) internal returns (uint256 now_) {
        now_ = vm.getBlockTimestamp() + d;
        vm.warp(now_);
    }

    function _one(address h) internal pure returns (address[] memory hs) {
        hs = new address[](1);
        hs[0] = h;
    }

    /// The old PoC: bob recycles passive alice's dividends after 90 days and gets a cut. Now a no-op.
    function test_recycleCannotSeizePassiveHolder() public {
        HookTokenV2 t = _launchDiv();
        _routerBuy(alice, t, 10 ether); // alice: passive holder
        _routerBuy(bob, t, 10 ether); // bob: attacker, also a holder
        _routerBuy(bob, t, 1 ether);
        div.reconcile();
        uint256 aliceOwed = div.pending(address(t), alice);
        uint256 bob0 = div.pending(address(t), bob);
        assertGt(aliceOwed, 0);

        vm.warp(block.timestamp + 91 days);
        vm.prank(bob);
        div.recycle(address(t), _one(alice));
        assertEq(div.pending(address(t), alice), aliceOwed, "passive holder keeps it all");
        assertEq(div.pending(address(t), bob), bob0, "the caller gains nothing");
    }

    function test_recycleOnlyAfterFailedPayoutAndNinetyDays() public {
        HookTokenV2 t = _launchDiv();
        RefuseAvax vault = new RefuseAvax();
        _routerBuy(alice, t, 30 ether); // the vault must be owed past the minimum: only a real send can fail
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        t.transfer(address(vault), half);
        _routerBuy(carol, t, 50 ether);
        div.reconcile();
        uint256 owed = div.pending(address(t), address(vault));
        assertGt(owed, 0);

        // Inactive for 90+ days but never failed: not recyclable.
        uint256 now_ = _skip(91 days);
        div.recycle(address(t), _one(address(vault)));
        assertEq(div.pending(address(t), address(vault)), owed, "no failed payout yet");

        // A failed push starts the clock.
        vm.prank(keeper);
        div.distribute(address(t), _one(address(vault)));
        uint256 failed = div.failedAt(div.poolOf(address(t)), address(vault));
        assertEq(failed, now_);
        _skip(30 days);
        vm.prank(keeper);
        div.distribute(address(t), _one(address(vault))); // fails again: the clock keeps the first failure
        assertEq(div.failedAt(div.poolOf(address(t)), address(vault)), failed);
        div.recycle(address(t), _one(address(vault)));
        assertEq(div.pending(address(t), address(vault)), owed, "not before 90 days after the failure");

        // A successful claim in between resets it.
        vault.setRefuse(false);
        vault.claim(div, address(t));
        assertEq(div.failedAt(div.poolOf(address(t)), address(vault)), 0);
        _skip(61 days);
        _routerBuy(carol, t, 50 ether);
        div.reconcile();
        uint256 owed2 = div.pending(address(t), address(vault));
        assertGt(owed2, 0);
        div.recycle(address(t), _one(address(vault)));
        assertEq(div.pending(address(t), address(vault)), owed2, "claimed since: not recyclable");

        // Fails again, 90 days pass: recycled to everyone.
        vault.setRefuse(true);
        vm.prank(keeper);
        div.distribute(address(t), _one(address(vault)));
        assertGt(div.failedAt(div.poolOf(address(t)), address(vault)), 0);
        _skip(91 days);
        uint256 a0 = div.pending(address(t), alice);
        div.recycle(address(t), _one(address(vault)));
        assertLt(div.pending(address(t), address(vault)), owed2, "recycled (it keeps its pro-rata cut of the refold)");
        assertGt(div.pending(address(t), alice), a0, "back to the holders");
        assertEq(div.failedAt(div.poolOf(address(t)), address(vault)), 0);
    }
}
