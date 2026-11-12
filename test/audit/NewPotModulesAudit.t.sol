// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {UnderwaterModule} from "../../contracts/v2/modules/UnderwaterModule.sol";
import {JackpotModule} from "../../contracts/v2/modules/JackpotModule.sol";
import {NewModulesBase} from "../v2/NewModulesBase.t.sol";

contract NewPotModulesAudit is NewModulesBase {
    UnderwaterModule uw;
    JackpotModule jp;
    uint32 uwId;
    uint32 jpId;
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        uw = new UnderwaterModule(address(hook), SAFE);
        uwId = modules.addModule(address(uw), '{"name":"Underwater"}');
        vm.prank(SAFE);
        uw.setKeeper(keeper);
        jp = new JackpotModule(address(hook));
        jpId = modules.addModule(address(jp), '{"name":"Quantum jackpot"}');
    }

    function _uwPot(HookTokenV2 t) internal view returns (uint256 pot) {
        (pot,,,,) = uw.stats(address(t));
    }

    function _l1(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    /// F-1 (fixed): two attacker wallets manufacture an "underwater" position by trading against each other
    /// (pump with C, buy high with A, dump C). A's basis is now valued at the pre-pump reference price, so the
    /// pump books no gap; with the 25% gap share and keeper-only rounds on top, the attack loses its fees.
    function test_underwater_selfTradeFakeGap() public {
        HookTokenV2 t =
            _launch(_one(uwId), _oneCfg(abi.encode(UnderwaterModule.Config(100, 0, 5 minutes, 10_000, 2_500))), 0);
        _graduateN(t, 40, 0);
        // organic volume by others fills the pot (carol churns; she is not underwater-listed)
        for (uint256 i; i < 10; ++i) {
            _routerBuy(carol, t, 300 ether);
            _routerSell(carol, t, t.balanceOf(carol));
        }
        uw.reconcile();
        uint256 pot0 = _uwPot(t);
        emit log_named_decimal_uint("pot before attack", pot0, 18);

        address A = makeAddr("attA");
        address C = makeAddr("attC");
        uint256 start = 2000 ether;
        vm.deal(A, start);
        vm.deal(C, start);

        _routerBuy(C, t, 900 ether); // pump
        _routerBuy(A, t, 300 ether); // buy high
        _routerSell(C, t, t.balanceOf(C)); // dump
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        uw.reconcile();
        vm.expectRevert(UnderwaterModule.NotKeeper.selector);
        uw.distribute(address(t), _l1(A)); // the attacker can't run the round itself
        vm.prank(keeper);
        (uint256 paid,) = uw.distribute(address(t), _l1(A));
        if (paid > 0) {
            vm.prank(A);
            hook.claim(NATIVE, A);
        }
        _routerSell(A, t, t.balanceOf(A));
        uint256 end = A.balance + C.balance;
        emit log_named_decimal_uint("paid to A", paid, 18);
        emit log_named_decimal_uint("attacker start", 2 * start, 18);
        emit log_named_decimal_uint("attacker end", end, 18);
        assertLt(end, 2 * start, "attacker loses money");
    }

    /// F-2 (fixed): one round per interval per pool, so separate calls in the same interval can't each spend
    /// roundBps of the pot.
    function test_underwater_roundBpsNotPerInterval() public {
        HookTokenV2 t =
            _launch(_one(uwId), _oneCfg(abi.encode(UnderwaterModule.Config(300, 0, 5 minutes, 500, 2_500))), 0);
        _graduateN(t, 40, 0);
        // many underwater wallets: buy after the pump, pumper dumps
        address P = makeAddr("pump");
        vm.deal(P, 1000 ether);
        _routerBuy(P, t, 200 ether);
        address[] memory ws = new address[](10);
        for (uint256 i; i < 10; ++i) {
            ws[i] = address(uint160(0xA000 + i));
            vm.deal(ws[i], 10 ether);
            _routerBuy(ws[i], t, 5 ether);
        }
        _routerSell(P, t, t.balanceOf(P));
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        uw.reconcile();
        uint256 pot0 = _uwPot(t);
        vm.prank(keeper);
        (uint256 total,) = uw.distribute(address(t), _l1(ws[0]));
        for (uint256 i = 1; i < 10; ++i) {
            vm.prank(keeper);
            vm.expectRevert();
            uw.distribute(address(t), _l1(ws[i]));
        }
        emit log_named_decimal_uint("pot", pot0, 18);
        emit log_named_decimal_uint("spent in one interval", total, 18);
        assertLe(total, (pot0 * 500) / 10_000, "at most roundBps of the pot per interval");
    }

    // ---------------------------------------------------------------- jackpot

    function _jpPot(HookTokenV2 t) internal view returns (uint256 pot) {
        (pot,,,,,,,) = jp.jackpot(address(t));
    }

    /// F-3 (fixed): a 1-wei gift to the drawn winner in the settle block no longer disqualifies it; only the
    /// amount received in that block is discounted from its holding.
    function test_jackpot_dustTransferForcesRollover() public {
        // minBuy above the graduation chunks so only the pool buys below get tickets ($443, under the $500 cap)
        HookTokenV2 t = _launch(_one(jpId), _oneCfg(abi.encode(JackpotModule.Config(200, 1 hours, 40 ether, 1))), 0);
        _graduateN(t, 40, 0);
        // bob: a large, honest ticket holder; alice: the griefer with a small ticket
        _routerBuy(bob, t, 1000 ether);
        _routerBuy(alice, t, 40 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        jp.settle(address(t)); // commits the draw
        (,,,,,, uint256 db,) = jp.jackpot(address(t));
        vm.roll(db + 1);
        // find a hash where bob wins (he holds ~95% of the tickets)
        vm.setBlockhash(db, keccak256("x"));
        uint256 pot = _jpPot(t);
        assertGt(pot, 0);
        // griefer: 1 wei to the winner, then settle, in the same block
        vm.prank(alice);
        t.transfer(bob, 1);
        (address winner, uint256 paid) = jp.settle(address(t));
        assertEq(winner, bob, "bob was drawn");
        assertEq(paid, pot, "and paid despite the dust");
        assertGe(t.balanceOf(bob), (1_000_000_000 ether * 1) / 10_000, "bob holds far more than minHold");
    }

    /// F-4 (fixed): there is no entry cap any more (append-only ticket log, binary-search draw), and minBuy
    /// must be worth at least $1, so 500 sybil entries lock nobody out. Two alternating sybil wallets make 500
    /// distinct log entries without loading 500 fork accounts.
    function test_jackpot_entryCapCapture() public {
        HookTokenV2 t = _launch(_one(jpId), _oneCfg(abi.encode(JackpotModule.Config(200, 1 hours, 0.1 ether, 1))), 0);
        _graduateN(t, 40, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        jp.settle(address(t)); // close the curve round (graduation buyers)
        (,,,,,, uint256 db,) = jp.jackpot(address(t));
        vm.roll(db + 1);
        vm.setBlockhash(db, keccak256("y"));
        jp.settle(address(t));
        (, uint256 round,,, uint256 entries,,,) = jp.jackpot(address(t));
        address s0 = makeAddr("syb0");
        address s1 = makeAddr("syb1");
        vm.deal(s0, 100 ether);
        vm.deal(s1, 100 ether);
        for (uint256 i = entries; i < 500; ++i) {
            _routerBuy(i % 2 == 0 ? s0 : s1, t, 0.1 ether);
        }
        (,,,, entries,,,) = jp.jackpot(address(t));
        assertGe(entries, 500);
        _routerBuy(bob, t, 1000 ether);
        assertEq(jp.ticketsOf(address(t), round, bob), 1000 ether, "honest whale gets its tickets");
    }
}
