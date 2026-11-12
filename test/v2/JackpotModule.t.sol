// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {JackpotModule} from "../../contracts/v2/modules/JackpotModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract JackpotModuleTest is NewModulesBase {
    JackpotModule jp;
    uint32 jpId;
    uint32 constant ROUND = 1 hours;

    function setUp() public override {
        super.setUp();
        jp = new JackpotModule(address(hook));
        jpId = modules.addModule(address(jp), '{"name":"Quantum jackpot"}');
    }

    function _cfg(uint16 bps, uint32 round, uint96 minBuy, uint16 hold) internal pure returns (bytes memory) {
        return abi.encode(JackpotModule.Config(bps, round, minBuy, hold));
    }

    function _launchJp(uint96 minBuy) internal returns (HookTokenV2 t) {
        t = _launch(_one(jpId), _oneCfg(_cfg(200, ROUND, minBuy, 1)), 0);
    }

    function _buy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
    }

    function _pot(HookTokenV2 t) internal view returns (uint256 pot) {
        (pot,,,,,,,) = jp.jackpot(address(t));
    }

    function _closed(HookTokenV2 t) internal view returns (uint256 closedRound, uint256 drawBlock) {
        (,,,,, closedRound, drawBlock,) = jp.jackpot(address(t));
    }

    /// Ends the open round, commits the draw, then settles it with block hash `h`.
    function _endAndDraw(HookTokenV2 t, bytes32 h) internal returns (address winner, uint256 paid) {
        vm.warp(vm.getBlockTimestamp() + ROUND + 1);
        (uint256 cr,) = _closed(t);
        if (cr == 0) {
            (winner, paid) = jp.settle(address(t)); // commits
            assertEq(winner, address(0));
        }
        (, uint256 db) = _closed(t);
        vm.roll(db + 1);
        vm.setBlockhash(db, h);
        (winner, paid) = jp.settle(address(t));
    }

    function test_configBoundsAndCaps() public {
        jp.validateConfig(_cfg(1, 10 minutes, 1, 1)); // the USD bound on minBuy is checked at launch
        jp.validateConfig(_cfg(500, 30 days, 1, 100));
        vm.expectRevert();
        jp.validateConfig(_cfg(0, ROUND, 1, 1));
        vm.expectRevert();
        jp.validateConfig(_cfg(501, ROUND, 1, 1));
        vm.expectRevert();
        jp.validateConfig(_cfg(100, 10 minutes - 1, 1, 1));
        vm.expectRevert();
        jp.validateConfig(_cfg(100, 30 days + 1, 1, 1));
        vm.expectRevert();
        jp.validateConfig(_cfg(100, ROUND, 0, 1));
        vm.expectRevert();
        jp.validateConfig(_cfg(100, ROUND, 1, 0));
        vm.expectRevert();
        jp.validateConfig(_cfg(100, ROUND, 1, 101));
        assertEq(jp.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER);
        assertEq(jp.conflictGroups(), 0);
    }

    /// Qualifying curve buys get tickets = quote spent; small buys and the creator get none but still pay.
    function test_curveTickets() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, 1 ether);
        _buy(bob, t, 0.05 ether);
        vm.prank(creator);
        pad.buy{value: 1 ether}(address(t), 0);
        _buy(alice, t, 0.5 ether);
        assertEq(jp.ticketsOf(address(t), 1, alice), 1.5 ether);
        assertEq(jp.ticketsOf(address(t), 1, bob), 0);
        assertEq(jp.ticketsOf(address(t), 1, creator), 0);
        (, uint256 round,, uint256 tickets, uint256 entries,,,) = jp.jackpot(address(t));
        assertEq(round, 1);
        assertEq(tickets, 1.5 ether);
        assertEq(entries, 1);
        jp.reconcile();
        assertEq(_pot(t), (2.55 ether * 200) / 10_000, "2% of every buy");
        // a sell adds 2% of its gross output
        uint256 p0 = _pot(t);
        uint256 bal = t.balanceOf(bob);
        vm.prank(bob);
        pad.sell(address(t), bal, 0);
        jp.reconcile();
        assertGt(_pot(t), p0);
    }

    /// Commit, too-early refusal, then the only entrant wins the whole pot as a claim in the hook.
    function test_settleSingleEntrant() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, 2 ether);
        vm.expectRevert(); // nothing closed yet and nothing to draw: settle is a no-op, canSettle false
        this.mustSettle(t);
        vm.warp(vm.getBlockTimestamp() + ROUND);
        assertTrue(jp.canSettle(address(t)));
        (address w, uint256 paid) = jp.settle(address(t));
        assertEq(w, address(0));
        assertEq(paid, 0);
        (uint256 cr, uint256 db) = _closed(t);
        assertEq(cr, 1);
        assertEq(db, vm.getBlockNumber() + 1);
        vm.expectRevert(abi.encodeWithSelector(JackpotModule.TooEarly.selector, db));
        jp.settle(address(t));
        vm.roll(db);
        vm.expectRevert(abi.encodeWithSelector(JackpotModule.TooEarly.selector, db));
        jp.settle(address(t));
        vm.roll(db + 1);
        vm.setBlockhash(db, keccak256("x"));
        uint256 pot = _pot(t);
        uint256 c0 = hook.claimable(alice, NATIVE);
        (w, paid) = jp.settle(address(t));
        assertEq(w, alice);
        assertEq(paid, pot);
        assertEq(hook.claimable(alice, NATIVE) - c0, pot);
        assertEq(_pot(t), 0);
        (cr,) = _closed(t);
        assertEq(cr, 0);
        (, uint256 round,,,,,,) = jp.jackpot(address(t));
        assertEq(round, 2);
        // alice withdraws AVAX from the hook
        uint256 owed = hook.claimable(alice, NATIVE);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        hook.claim(NATIVE, alice);
        assertEq(alice.balance - b0, owed);
    }

    function mustSettle(HookTokenV2 t) external {
        require(jp.canSettle(address(t)), "nothing to settle");
    }

    /// A winner that no longer holds minHoldBps loses: the pot rolls over to the next round.
    function test_rollsOverWhenWinnerSold() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, 2 ether);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t), bal, 0);
        jp.reconcile();
        uint256 pot = _pot(t);
        (address w, uint256 paid) = _endAndDraw(t, keccak256("y"));
        assertEq(w, alice);
        assertEq(paid, 0);
        assertEq(_pot(t), pot, "pot rolled over");
        // next round: bob wins it all
        _buy(bob, t, 1 ether);
        jp.reconcile();
        pot = _pot(t);
        (w, paid) = _endAndDraw(t, keccak256("z"));
        assertEq(w, bob);
        assertEq(paid, pot);
    }

    /// The winner can't flash-buy the holding back inside the settle block.
    function test_sameBlockTopUpDoesNotCount() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, 2 ether);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t), bal, 0);
        vm.warp(vm.getBlockTimestamp() + ROUND);
        jp.settle(address(t)); // commit
        (, uint256 db) = _closed(t);
        vm.roll(db + 1);
        vm.setBlockhash(db, keccak256("flash"));
        _buy(alice, t, 1 ether); // same block as the settle
        jp.reconcile();
        uint256 pot = _pot(t);
        (address w, uint256 paid) = jp.settle(address(t));
        assertEq(w, alice);
        assertEq(paid, 0, "same-block holding ignored");
        assertEq(_pot(t), pot);
    }

    /// Past 256 blocks the hash is gone: settle re-commits to a fresh block instead of drawing.
    function test_recommitAfter256Blocks() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, 1 ether);
        vm.warp(vm.getBlockTimestamp() + ROUND);
        jp.settle(address(t));
        (, uint256 db) = _closed(t);
        vm.roll(db + 300);
        (address w,) = jp.settle(address(t));
        assertEq(w, address(0));
        (uint256 cr, uint256 db2) = _closed(t);
        assertEq(cr, 1);
        assertEq(db2, vm.getBlockNumber() + 1);
        vm.roll(db2 + 1);
        vm.setBlockhash(db2, keccak256("late"));
        (w,) = jp.settle(address(t));
        assertEq(w, alice);
    }

    /// Pool phase: router buys get tickets, aggregator buys only pay, sells pay; the open round keeps running
    /// while an earlier draw waits and closes as soon as it is settled.
    function test_poolPhaseAndOverlappingRounds() public {
        HookTokenV2 t = _launch(_one(jpId), _oneCfg(_cfg(200, ROUND, 0.1 ether, 1)), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        // the graduation buys were curve buys: 40 wallets in round 1
        (,,, uint256 tickets, uint256 entries,,,) = jp.jackpot(address(t));
        assertGt(entries, 30);
        assertGt(tickets, 0);
        // round 1 ends; a router buy closes it (commits) and opens round 2 with its tickets
        vm.warp(vm.getBlockTimestamp() + ROUND);
        uint256 got = _routerBuy(alice, t, 5 ether);
        (uint256 cr,) = _closed(t);
        assertEq(cr, 1);
        assertEq(jp.ticketsOf(address(t), 2, alice), 5 ether);
        // an aggregator buy pays the pot but gets no tickets
        jp.reconcile();
        uint256 p0 = _pot(t);
        agg.swap(key, true, -int256(5 ether));
        jp.reconcile();
        assertEq(_pot(t) - p0, 0.1 ether);
        (,,, tickets,,,,) = jp.jackpot(address(t));
        assertEq(tickets, 5 ether);
        // sell pays too
        p0 = _pot(t);
        _routerSell(alice, t, got / 2);
        jp.reconcile();
        assertGt(_pot(t), p0);
        // round 2 ends without a settle of round 1: it keeps running and takes more tickets
        vm.warp(vm.getBlockTimestamp() + 2 * ROUND);
        _routerBuy(bob, t, 1 ether);
        assertEq(jp.ticketsOf(address(t), 2, bob), 1 ether);
        // settle round 1, which closes round 2 at once
        (, uint256 db) = _closed(t);
        vm.roll(db + 1);
        vm.setBlockhash(db, keccak256("r1"));
        (address w, uint256 paid) = jp.settle(address(t));
        assertTrue(w != address(0));
        assertGt(paid, 0);
        (cr, db) = _closed(t);
        assertEq(cr, 2, "round 2 closed right after");
        assertEq(db, vm.getBlockNumber() + 1);
        vm.roll(db + 1);
        vm.setBlockhash(db, keccak256("r2"));
        (w,) = jp.settle(address(t));
        assertTrue(w == alice || w == bob);
    }

    /// No entry cap: 500+ log entries (two wallets alternating, so the fork needn't load 500 accounts), a new
    /// wallet still gets tickets, and the binary-search draw lands on the right entry.
    function test_manyEntriesNoCap() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        address a = makeAddr("sybA");
        address b = makeAddr("sybB");
        for (uint256 i; i < 500; ++i) {
            _buy(i % 2 == 0 ? a : b, t, 0.1 ether);
        }
        (,,, uint256 tickets, uint256 entries,,,) = jp.jackpot(address(t));
        assertEq(entries, 500);
        assertEq(tickets, 50 ether);
        _buy(alice, t, 50 ether); // as many tickets as all 500 entries together
        assertEq(jp.ticketsOf(address(t), 1, alice), 50 ether);
        _buy(alice, t, 1 ether); // consecutive buys by one wallet merge
        (,,,, entries,,,) = jp.jackpot(address(t));
        assertEq(entries, 501);
        uint256 aliceWins;
        for (uint256 k; k < 6; ++k) {
            HookTokenV2 t2 = k == 0 ? t : _launchJp(0.1 ether);
            if (k > 0) {
                for (uint256 i; i < 20; ++i) _buy(i % 2 == 0 ? a : b, t2, 0.1 ether);
                _buy(alice, t2, 2 ether);
            }
            (address w,) = _endAndDraw(t2, keccak256(abi.encode(k)));
            assertTrue(w == a || w == b || w == alice);
            if (w == alice) ++aliceWins;
        }
        assertGt(aliceWins, 0, "half the tickets wins sometimes");
        assertLt(aliceWins, 6, "and loses sometimes");
    }

    /// minBuy must be worth $1 .. $500 at launch (AVAX ~ $11 on the fork block).
    function test_minBuyUsdBounds() public {
        assertApproxEqRel(jp.minBuyUsd(address(0), 1 ether), 11.07e18, 0.01e18);
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "J";
        a.symbol = "J";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(jpId);
        uint256 fee = pad.creationFee();
        a.moduleConfigs = _oneCfg(_cfg(200, ROUND, 0.05 ether, 1)); // $0.55
        vm.expectRevert();
        vm.prank(creator);
        pad.launch{value: fee}(a);
        a.moduleConfigs = _oneCfg(_cfg(200, ROUND, 46 ether, 1)); // $509
        vm.expectRevert();
        vm.prank(creator);
        pad.launch{value: fee}(a);
        a.moduleConfigs = _oneCfg(_cfg(200, ROUND, 45 ether, 1)); // $498
        vm.prank(creator);
        pad.launch{value: fee}(a);
    }

    /// No tickets for 30 days: the pot goes to the creator.
    function test_orphanPotToCreator() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        vm.prank(creator);
        pad.buy{value: 5 ether}(address(t), 0);
        jp.reconcile();
        uint256 pot = _pot(t);
        assertGt(pot, 0);
        vm.warp(vm.getBlockTimestamp() + 29 days);
        jp.settle(address(t));
        assertEq(_pot(t), pot);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertTrue(jp.canSettle(address(t)));
        jp.settle(address(t));
        assertEq(_pot(t), 0);
        assertEq(hook.claimable(creator, NATIVE), pot);
    }

    function test_rescueAfterDisable() public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, 3 ether);
        jp.reconcile();
        uint256 pot = _pot(t);
        vm.expectRevert();
        jp.rescue(address(t));
        modules.disable(jpId);
        jp.rescue(address(t));
        assertEq(hook.claimable(creator, NATIVE), pot);
    }

    /// The winner is always an entrant, odds follow tickets, and the pot paid is the confirmed pot.
    /// forge-config: default.fuzz.runs = 32
    function testFuzz_winnerIsEntrant(uint256 a, uint256 b, bytes32 h) public {
        HookTokenV2 t = _launchJp(0.1 ether);
        _buy(alice, t, bound(a, 0.1 ether, 20 ether));
        _buy(bob, t, bound(b, 0.1 ether, 20 ether));
        if (h == bytes32(0)) h = keccak256("0");
        jp.reconcile();
        uint256 pot = _pot(t);
        (address w, uint256 paid) = _endAndDraw(t, h);
        assertTrue(w == alice || w == bob);
        assertEq(paid, pot);
        assertEq(hook.claimable(w, NATIVE), pot);
        assertEq(jp.accounted(address(0)), hook.claimable(address(jp), NATIVE));
    }
}
