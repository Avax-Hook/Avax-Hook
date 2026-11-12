// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {V2Base} from "./V2Base.t.sol";

/// `sellDeposited` only sells what a trusted caller deposited since the last curve trade: tokens anyone
/// sent to the launchpad before (strays) never count as its deposit.
contract SellDepositedStrayTest is V2Base {
    address orders = makeAddr("orders");

    function _token() internal returns (HookTokenV2 t) {
        t = _launch(new uint32[](0), new bytes[](0), 100);
        pad.setTrustedCaller(orders, true);
    }

    function _buy(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 got) {
        uint256 b = t.balanceOf(who);
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
        got = t.balanceOf(who) - b;
    }

    function test_strayTokensDontCountAsDeposit() public {
        HookTokenV2 t = _token();
        uint256 aliceBag = _buy(alice, t, 1 ether);
        // alice sends tokens to the launchpad by mistake
        vm.prank(alice);
        t.transfer(address(pad), aliceBag);
        _buy(bob, t, 0.1 ether); // any curve trade records them as strays

        vm.prank(orders);
        vm.expectRevert(HookLaunchpadV2.BadArgs.selector);
        pad.sellDeposited(address(t), aliceBag, 0);

        // a real deposit in the same transaction sells, and only up to its size
        uint256 bobBag = t.balanceOf(bob);
        vm.prank(bob);
        t.transfer(address(pad), bobBag); // stands in for the trusted caller's transferFrom
        vm.prank(orders);
        vm.expectRevert(HookLaunchpadV2.BadArgs.selector);
        pad.sellDeposited(address(t), bobBag + 1, 0);
        uint256 q0 = orders.balance;
        vm.prank(orders);
        pad.sellDeposited(address(t), bobBag, 0);
        assertGt(orders.balance, q0, "deposit sold");

        // the deposit is used up; the strays still can't be sold
        vm.prank(orders);
        vm.expectRevert(HookLaunchpadV2.BadArgs.selector);
        pad.sellDeposited(address(t), 1, 0);
    }

    function test_strayBeforeAnyTradeIsAbsorbedByNextSell() public {
        HookTokenV2 t = _token();
        uint256 bag = _buy(alice, t, 1 ether);
        vm.prank(alice);
        pad.sell(address(t), bag / 2, 0);
        vm.prank(alice);
        t.transfer(address(pad), bag / 4); // stray after the last trade ...
        vm.prank(bob);
        pad.buy{value: 0.01 ether}(address(t), 0); // ... absorbed by the next one
        vm.prank(orders);
        vm.expectRevert(HookLaunchpadV2.BadArgs.selector);
        pad.sellDeposited(address(t), 1, 0);
    }
}
