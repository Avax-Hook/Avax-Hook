// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AvaxHookRouterV2} from "../../../contracts/v2/AvaxHookRouterV2.sol";
import {RisingFloorModule} from "../../../contracts/v2/modules/RisingFloorModule.sol";
import {UnderwaterModule} from "../../../contracts/v2/modules/UnderwaterModule.sol";
import {JackpotModule} from "../../../contracts/v2/modules/JackpotModule.sol";
import {LockEarnModule} from "../../../contracts/v2/modules/LockEarnModule.sol";
import {NewModulesBase} from "../../v2/NewModulesBase.t.sol";

/// Final audit ("pots"): multi-token / multi-user solvency of the pot modules sharing one quote, and PoCs.
contract PotsFinalTest is NewModulesBase {
    RisingFloorModule rf;
    UnderwaterModule uw;
    JackpotModule jp;
    LockEarnModule le;
    uint32 rfId;
    uint32 uwId;
    uint32 jpId;
    uint32 leId;
    address keeper = makeAddr("keeper");

    HookTokenV2[] toks;
    address[] users;
    uint256 seed;

    function setUp() public override {
        super.setUp();
        _mockAvaxUsd(20e18);
        rf = new RisingFloorModule(address(hook));
        rfId = modules.addModule(address(rf), '{"name":"Rising floor"}');
        uw = new UnderwaterModule(address(hook), SAFE);
        uwId = modules.addModule(address(uw), '{"name":"Underwater"}');
        vm.prank(SAFE);
        uw.setKeeper(keeper);
        jp = new JackpotModule(address(hook));
        jpId = modules.addModule(address(jp), '{"name":"Quantum jackpot"}');
        le = new LockEarnModule(address(hook));
        leId = modules.addModule(address(le), '{"name":"Lock & earn"}');
    }

    // ---------------------------------------------------------------- helpers

    function _allFour(uint16 bps) internal returns (HookTokenV2 t) {
        uint32[] memory ids = new uint32[](4);
        bytes[] memory cfgs = new bytes[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (rfId, uwId, jpId, leId);
        cfgs[0] = abi.encode(RisingFloorModule.Config(bps));
        cfgs[1] = abi.encode(UnderwaterModule.Config(bps, 0, 5 minutes, 10_000, 5_000));
        cfgs[2] = abi.encode(JackpotModule.Config(bps, 10 minutes, 1 ether, 1));
        cfgs[3] = abi.encode(LockEarnModule.Config(bps, 1 hours));
        t = _launch(ids, cfgs, 100);
    }

    function _rnd() internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return seed;
    }

    function _sumRf() internal view returns (uint256 s) {
        for (uint256 i; i < toks.length; ++i) {
            (,, uint256 tr, uint256 pend,,,) = rf.stats(address(toks[i]));
            s += tr + pend;
        }
    }

    function _sumUw() internal view returns (uint256 s) {
        for (uint256 i; i < toks.length; ++i) {
            (uint256 pot,,,,) = uw.stats(address(toks[i]));
            s += pot;
        }
    }

    function _sumJp() internal view returns (uint256 s) {
        for (uint256 i; i < toks.length; ++i) {
            (uint256 pot,,,,,,,) = jp.jackpot(address(toks[i]));
            s += pot;
        }
    }

    /// distributed + carry + unverified - paid (what the module still owes or holds for the pool)
    function _sumLe() internal view returns (uint256 s) {
        for (uint256 i; i < toks.length; ++i) {
            (,,, uint256 distributed, uint256 paid, uint256 carry) = le.stats(address(toks[i]));
            s += distributed + carry - paid;
        }
    }

    function _claim(address m) internal view returns (uint256) {
        return hook.claimable(m, NATIVE);
    }

    function _checkInvariants() internal {
        // any one reconcile settles the module's single pending credit (no callback is running)
        rf.reconcile();
        uw.reconcile();
        jp.reconcile();
        le.reconcile();
        assertEq(_sumRf(), rf.accounted(address(0)) + rf.cash(address(0)), "rf: shares == accounted + cash");
        assertLe(rf.accounted(address(0)), _claim(address(rf)), "rf: accounted backed by hook claim");
        assertGe(address(rf).balance, rf.cash(address(0)), "rf: cash backed");
        assertEq(_sumUw(), uw.accounted(address(0)), "uw: pots == accounted");
        assertLe(uw.accounted(address(0)), _claim(address(uw)), "uw: backed");
        assertEq(_sumJp(), jp.accounted(address(0)), "jp: pots == accounted");
        assertLe(jp.accounted(address(0)), _claim(address(jp)), "jp: backed");
        assertEq(_sumLe(), le.accounted(address(0)) + le.cash(address(0)), "le: owed == accounted + cash");
        assertLe(le.accounted(address(0)), _claim(address(le)), "le: backed");
        assertGe(address(le).balance, le.cash(address(0)), "le: cash backed");
    }

    function _sortedUsers() internal view returns (address[] memory s) {
        s = users;
        for (uint256 i = 1; i < s.length; ++i) {
            for (uint256 j = i; j > 0 && s[j - 1] > s[j]; --j) {
                (s[j - 1], s[j]) = (s[j], s[j - 1]);
            }
        }
    }

    function _act() internal {
        uint256 r = _rnd();
        address u = users[r % users.length];
        HookTokenV2 t = toks[(r >> 8) % toks.length];
        uint256 kind = (r >> 16) % 10;
        uint256 bal = t.balanceOf(u);
        if (kind <= 2) {
            uint256 amt = 1 ether + ((r >> 32) % 60 ether);
            vm.prank(u);
            (bool ok,) = address(router).call{value: amt}(
                abi.encodeCall(AvaxHookRouterV2.buy, (address(t), amt, 0, address(0), block.timestamp, ""))
            );
            ok;
        } else if (kind == 3 && bal > 0) {
            uint256 amt = (bal * (1 + (r >> 32) % 100)) / 100;
            vm.prank(u);
            (bool ok,) =
                address(router).call(abi.encodeCall(AvaxHookRouterV2.sell, (address(t), amt, 0, block.timestamp, "")));
            ok;
        } else if (kind == 4 && bal > 0) {
            uint256 amt = (bal * (1 + (r >> 32) % 100)) / 100;
            vm.prank(u);
            (bool ok,) = address(rf).call(abi.encodeCall(RisingFloorModule.redeem, (address(t), amt, 0)));
            ok;
        } else if (kind == 5 && bal > 2 ether) {
            uint256 amt = (bal * (1 + (r >> 32) % 50)) / 100;
            uint256 secs = 1 hours + (r >> 64) % 20 days;
            vm.prank(u);
            (bool ok,) =
                address(le).call(abi.encodeCall(LockEarnModule.lock, (address(t), amt, block.timestamp + secs)));
            ok;
        } else if (kind == 6) {
            vm.prank(u);
            (bool ok,) = address(le).call(abi.encodeCall(LockEarnModule.claim, (address(t))));
            ok;
        } else if (kind == 7) {
            (,,,,, uint256 closed, uint256 db,) = jp.jackpot(address(t));
            if (closed != 0 && block.number > db) vm.setBlockhash(db, bytes32(_rnd()));
            (bool ok,) = address(jp).call(abi.encodeCall(JackpotModule.settle, (address(t))));
            ok;
            vm.prank(u);
            (ok,) = address(hook).call(abi.encodeWithSignature("claim(address,address)", address(0), u));
        } else if (kind == 8) {
            vm.prank(keeper);
            (bool ok,) = address(uw).call(abi.encodeCall(UnderwaterModule.distribute, (address(t), _sortedUsers())));
            ok;
        } else {
            vm.warp(block.timestamp + 1 minutes + (r >> 32) % 2 days);
            vm.roll(block.number + 1 + (r >> 80) % 50);
        }
    }

    // ---------------------------------------------------------------- invariant / fuzz

    /// forge-config: default.fuzz.runs = 3
    function testFuzz_pots_multiTokenSolvency(uint256 s) public {
        seed = s;
        for (uint256 i; i < 3; ++i) {
            HookTokenV2 t = _allFour(uint16(100 + 150 * i));
            _graduateN(t, 20, 0);
            toks.push(t);
        }
        for (uint256 i; i < 6; ++i) {
            address u = address(uint160(0xC0FFEE00 + i * 7919));
            users.push(u);
            vm.deal(u, 1_000_000 ether);
            vm.startPrank(u);
            for (uint256 k; k < toks.length; ++k) {
                toks[k].approve(address(router), type(uint256).max);
                toks[k].approve(address(rf), type(uint256).max);
            }
            vm.stopPrank();
        }
        _checkInvariants();
        for (uint256 step; step < 120; ++step) {
            _act();
            _checkInvariants();
        }

        // drain: every lock expires, everyone claims and redeems everything; nothing may revert for funds
        vm.warp(block.timestamp + 400 days);
        vm.roll(block.number + 10);
        for (uint256 k; k < toks.length; ++k) {
            le.poke(address(toks[k]));
        }
        for (uint256 i; i < users.length; ++i) {
            address u = users[i];
            for (uint256 k; k < toks.length; ++k) {
                HookTokenV2 t = toks[k];
                (,, uint256 pending) = le.lockOf(address(t), u);
                if (pending > 0) {
                    vm.prank(u);
                    le.claim(address(t));
                }
                uint256 bal = t.balanceOf(u);
                if (bal > 0 && rf.quoteRedeem(address(t), bal) > 0) {
                    vm.prank(u);
                    rf.redeem(address(t), bal, 0);
                }
            }
        }
        _checkInvariants();
        for (uint256 k; k < toks.length; ++k) {
            (,,,, uint256 redeemed, uint256 burned,) = rf.stats(address(toks[k]));
            (,, uint256 uwPaid,,) = uw.stats(address(toks[k]));
            (,,,,,,, uint256 jpPaid) = jp.jackpot(address(toks[k]));
            (,,, uint256 dist, uint256 lePaid,) = le.stats(address(toks[k]));
            emit log_named_uint("rf redeemed", redeemed);
            emit log_named_uint("rf burned", burned);
            emit log_named_uint("uw paid", uwPaid);
            emit log_named_uint("jp paid", jpPaid);
            emit log_named_uint("le distributed", dist);
            emit log_named_uint("le paid", lePaid);
        }
    }

    function test_pots_solvencySeed() public {
        testFuzz_pots_multiTokenSolvency(42);
    }

    // ---------------------------------------------------------------- PoC: LockEarn empty batches

    /// Extending a lock leaves the old day's batch empty but its bitmap bit set. When the pool is idle across
    /// several such days, the first trade's `_advance` (MAX_STEPS = 8) writes `snap` into each empty batch slot
    /// (0 -> non-zero SSTORE, ~22k each), which can exceed the 200k module budget. LockEarn has BLOCKS_SELLS,
    /// so neither buys nor sells are isolated: every trade reverts until someone calls `poke`.
    /// Run with --isolate (per-transaction gas accounting, as on chain).
    function test_pots_lockEarnEmptyBatchesBrickTrades() public {
        (bool buyOk, bool sellOk, HookTokenV2 t) = _emptyBatches(12);
        assertTrue(buyOk, "regression: empty batches are skipped, the buy fits the module gas budget");
        assertTrue(sellOk, "and so does the sell");
        // anyone can unbrick with poke
        le.poke(address(t));
        _routerBuy(bob, t, 1 ether);
    }

    /// Control: the same idle stretch with only 3 empty batches trades fine (the revert above is the gas).
    function test_pots_lockEarnEmptyBatchesControl() public {
        (bool buyOk, bool sellOk,) = _emptyBatches(3);
        assertTrue(buyOk && sellOk, "few batches: trades work");
    }

    function _emptyBatches(uint256 n) internal returns (bool buyOk, bool sellOk, HookTokenV2 t) {
        t = _launch(_one(leId), _oneCfg(abi.encode(LockEarnModule.Config(100, 1 hours))), 0);
        _graduateN(t, 20, 0);
        address h = _holder(0);
        uint256 bal = t.balanceOf(h);
        // a real lock (>= 1 token) so credits fold and perShare becomes non-zero
        vm.prank(h);
        le.lock(address(t), bal / 2, block.timestamp + 40 days);
        _routerBuy(alice, t, 10 ether);
        _routerBuy(alice, t, 10 ether);
        le.poke(address(t));
        // attacker: 1 wei lock, extended day by day -> empty batches with their bits set on 12 consecutive days
        address a = makeAddr("griefer");
        vm.deal(a, 10 ether);
        _routerBuy(a, t, 1 ether);
        uint256 base = block.timestamp;
        vm.startPrank(a);
        le.lock(address(t), 1, base + 1 days);
        for (uint256 d = 2; d <= n + 1; ++d) {
            le.lock(address(t), 0, base + d * 1 days);
        }
        vm.stopPrank();
        // idle for 12 days, then the next trade must expire 8 (empty) batches inside the 200k budget
        vm.warp(base + 13 days);
        vm.roll(block.number + 100);
        uint256 hb = t.balanceOf(alice);
        vm.prank(alice);
        t.approve(address(router), hb);
        vm.prank(alice);
        try router.sell(address(t), hb / 10, 0, block.timestamp, "") {
            sellOk = true;
        } catch {}
        vm.prank(bob);
        try router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp, "") {
            buyOk = true;
        } catch {}
    }
}
