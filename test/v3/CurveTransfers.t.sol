// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {HookTokenV3} from "../../contracts/v3/HookTokenV3.sol";
import {DexOnlyModule} from "../../contracts/v2/modules/DexOnlyModule.sol";
import {HolderVestingModule} from "../../contracts/v2/modules/HolderVestingModule.sol";
import {KingOfTheHillModule} from "../../contracts/v2/modules/KingOfTheHillModule.sol";
import {MaxPerWalletModule} from "../../contracts/v2/modules/MaxPerWalletModule.sol";
import {CreditModule} from "./V3Mocks.sol";
import {V3Base} from "./V3Base.t.sol";

/// What v3 is for: a token moves while it is still on the curve. The same flows revert on v2 with
/// `CurvePhaseTransfer` (test/v2/V1PortCurvePhase.t.sol holds that side).
contract CurveTransfers is V3Base {
    MaxPerWalletModule mpw;
    KingOfTheHillModule koth;
    DexOnlyModule dexOnly;
    HolderVestingModule vesting;
    CreditModule credit;
    uint32 mpwId;
    uint32 kothId;
    uint32 dexOnlyId;
    uint32 vestingId;
    uint32 creditId;

    address payee = makeAddr("payee");

    function _registerModules() internal override {
        mpw = new MaxPerWalletModule(address(hook));
        koth = new KingOfTheHillModule(address(hook));
        dexOnly = new DexOnlyModule(address(hook));
        vesting = new HolderVestingModule(address(hook));
        credit = new CreditModule(address(hook), payee, 100);
        mpwId = modules.addModule(address(mpw), '{"name":"Max per wallet"}');
        kothId = modules.addModule(address(koth), '{"name":"King of the Hill"}');
        dexOnlyId = modules.addModule(address(dexOnly), '{"name":"DEX only"}');
        vestingId = modules.addModule(address(vesting), '{"name":"Holder vesting"}');
        creditId = modules.addModule(address(credit), '{"name":"Credit probe"}');
    }

    // ---------------------------------------------------------------- the plain cases

    /// Wallet to wallet on the curve, and the receiver can sell what was sent.
    function test_sendOnCurve() public {
        HookTokenV3 t = _launch();
        uint256 got = _buy(alice, t, 1 ether);
        assertGt(got, 0, "bought");
        assertFalse(t.tradingOpen(), "still on the curve");

        uint128 soldBefore = pad.getLaunch(address(t)).tokensSold;
        vm.prank(alice);
        t.transfer(bob, got / 2);
        assertEq(t.balanceOf(bob), got / 2, "bob holds the sent half");
        assertEq(t.balanceOf(alice), got - got / 2, "alice kept the rest");
        assertEq(pad.getLaunch(address(t)).tokensSold, soldBefore, "a send is not a sale");

        // What bob was sent is his to sell on the curve (the launchpad pulls it, no approve needed).
        uint256 avaxBefore = bob.balance;
        vm.prank(bob);
        pad.sell(address(t), got / 2, 0);
        assertEq(t.balanceOf(bob), 0, "sold it all");
        assertGt(bob.balance, avaxBefore, "paid in AVAX");
        assertLt(pad.getLaunch(address(t)).tokensSold, soldBefore, "that one was a sale");
    }

    /// transferFrom works too: an allowance on the curve is an ordinary allowance.
    function test_transferFromOnCurve() public {
        HookTokenV3 t = _launch();
        uint256 got = _buy(alice, t, 1 ether);
        vm.prank(alice);
        t.approve(bob, got);
        vm.prank(bob);
        t.transferFrom(alice, carol, got);
        assertEq(t.balanceOf(carol), got, "carol got it");
        assertEq(t.allowance(alice, bob), 0, "allowance spent");
    }

    /// Burning on the curve: the supply is the same, the dead address holds it.
    function test_burnOnCurve() public {
        HookTokenV3 t = _launch();
        uint256 got = _buy(alice, t, 1 ether);
        vm.prank(alice);
        t.transfer(DEAD, got);
        assertEq(t.balanceOf(DEAD), got, "burned to the dead address");
        assertEq(t.totalSupply(), 1_000_000_000 ether, "supply untouched");

        // The curve runs on, and the burned tokens stay counted as sold: they were.
        assertEq(pad.getLaunch(address(t)).tokensSold, got, "still sold");
        PoolKey memory key = _graduate(t);
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated with burned tokens outstanding");
        assertGt(t.balanceOf(DEAD), got, "graduation burned its dust on top");
        assertTrue(hook.isOpen(_id(key)), "pool open");
    }

    /// Tokens sent to the launchpad itself during the curve are burned as dust at graduation, as a
    /// v2 launch's would be (`to == launchpad` was the one move v2 allowed).
    function test_strayTransferToLaunchpadDoesNotBreakGraduation() public {
        HookTokenV3 t = _launch();
        uint256 got = _buy(alice, t, 1 ether);
        vm.prank(alice);
        t.transfer(address(pad), got);
        _graduate(t);
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        assertEq(t.balanceOf(address(pad)), 0, "the launchpad keeps nothing");
    }

    /// Sends during the curve do not change where the pool opens.
    function test_graduationAfterSendsOpensThePool() public {
        HookTokenV3 t = _launch();
        uint256 got = _buy(alice, t, 1 ether);
        vm.startPrank(alice);
        t.transfer(bob, got / 3);
        t.transfer(carol, got / 3);
        vm.stopPrank();

        PoolKey memory key = _graduate(t);
        assertTrue(hook.isOpen(_id(key)), "pool open");
        assertTrue(t.tradingOpen(), "trading flag set at graduation");
        // Still ordinary transfers afterwards.
        vm.prank(bob);
        t.transfer(carol, 1 ether);
    }

    // ---------------------------------------------------------------- transfer rules on the curve

    /// A wallet cap now bites on the curve: without it a buyer would walk around the cap by sending to
    /// a second wallet before graduation.
    function test_maxPerWalletHoldsOnCurve() public {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = mpwId;
        cfgs[0] = abi.encode(MaxPerWalletModule.Config(500, 0, false)); // 5% of supply, forever
        HookTokenV3 t = _launch(ids, cfgs);

        uint256 cap = (1_000_000_000 ether * 500) / 10_000;
        _buyUntil(alice, t, (cap * 3) / 4);
        _buyUntil(bob, t, (cap * 3) / 4);
        uint256 room = cap - t.balanceOf(bob);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MaxPerWalletModule.MaxWalletExceeded.selector, bob, cap + 1, cap)
        );
        t.transfer(bob, room + 1);

        vm.prank(alice);
        t.transfer(bob, room); // exactly the cap is fine
        assertEq(t.balanceOf(bob), cap, "bob sits on the cap");
    }

    /// A buy that vests is locked whether the token has graduated or not.
    function test_vestingBlocksSendOnCurve() public {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = vestingId;
        // every buy over 0.1% of supply vests, nothing unlocks for a day, then 25% a day
        cfgs[0] = abi.encode(HolderVestingModule.Config(0, 10, 1 days, 2_500, 1 days));
        HookTokenV3 t = _launch(ids, cfgs);

        uint256 got = _buy(alice, t, 1 ether);
        assertGt(got, (1_000_000_000 ether * 10) / 10_000, "the buy is big enough to vest");

        vm.prank(alice);
        vm.expectPartialRevert(HolderVestingModule.StillLocked.selector);
        t.transfer(bob, 1);

        // A cliff and one period on, a quarter is free; the rest still is not.
        vm.warp(block.timestamp + 2 days + 1);
        uint256 free = got / 4;
        vm.prank(alice);
        t.transfer(bob, free);
        assertEq(t.balanceOf(bob), free, "the unlocked quarter moved");
        vm.prank(alice);
        vm.expectPartialRevert(HolderVestingModule.StillLocked.selector);
        t.transfer(bob, free);

        // And the whole lot once the schedule is done.
        vm.warp(block.timestamp + 10 days);
        uint256 rest = t.balanceOf(alice); // read before the prank: the call would consume it
        vm.prank(alice);
        t.transfer(bob, rest);
        assertEq(t.balanceOf(alice), 0, "fully vested");
    }

    /// Sending gives the crown up, on the curve as in the pool.
    function test_crownLostBySendingOnCurve() public {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = kothId;
        cfgs[0] = abi.encode(KingOfTheHillModule.Config(0.1 ether, 500, 50, 0, false));
        HookTokenV3 t = _launch(ids, cfgs);

        uint256 got = _buy(alice, t, 1 ether);
        (address king,,,) = koth.currentKing(address(t));
        assertEq(king, alice, "alice is king from a curve buy");

        vm.prank(alice);
        t.transfer(bob, got / 10);
        (king,,,) = koth.currentKing(address(t));
        assertEq(king, address(0), "the crown is given up by sending");
    }

    /// "No wallet-to-wallet": a rule the curve lock used to enforce by accident, and now the module does.
    function test_dexOnlyRefusesWalletToWalletOnCurve() public {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = dexOnlyId;
        cfgs[0] = abi.encode(DexOnlyModule.Config(0)); // forever
        HookTokenV3 t = _launch(ids, cfgs);

        uint256 got = _buy(alice, t, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DexOnlyModule.WalletToWallet.selector, alice, bob));
        t.transfer(bob, got / 2);

        // Selling back into the curve is not a wallet-to-wallet move.
        vm.prank(alice);
        pad.sell(address(t), got, 0);
        assertEq(t.balanceOf(alice), 0, "sold");
    }

    // ---------------------------------------------------------------- claims

    /// A module's token credit earned on the curve pays out at once. On v2 the hook's transfer to the
    /// payee hit the curve lock, so every token claim waited for graduation.
    function test_tokenClaimPaysOutOnTheCurve() public {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = creditId;
        cfgs[0] = "";
        HookTokenV3 t = _launch(ids, cfgs);

        _buy(alice, t, 1 ether);
        uint256 owed = hook.claimable(payee, Currency.wrap(address(t)));
        assertGt(owed, 0, "the module booked a token credit on the curve");

        vm.prank(payee);
        hook.claim(Currency.wrap(address(t)), payee);
        assertEq(t.balanceOf(payee), owed, "paid before graduation");
        assertEq(hook.claimable(payee, Currency.wrap(address(t))), 0, "claim cleared");
    }

    // ---------------------------------------------------------------- helpers

    /// Buys in small steps until `who` holds at least `want` — the curve's price in AVAX is whatever the
    /// live QuoteRegistry says, so the tests never assume a token amount for a given buy.
    function _buyUntil(address who, HookTokenV3 t, uint256 want) internal {
        for (uint256 i; i < 60 && t.balanceOf(who) < want; ++i) {
            vm.prank(who);
            pad.buy{value: 1 ether}(address(t), 0);
        }
        assertGe(t.balanceOf(who), want, "bought enough");
    }
}
