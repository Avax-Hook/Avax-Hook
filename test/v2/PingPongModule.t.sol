// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {PingPongModule} from "../../contracts/v2/modules/PingPongModule.sol";
import {NewModulesBase, MultiSwapper} from "./NewModulesBase.t.sol";

/// Each top-level call is its own transaction here (the rule counts swaps per transaction).
/// forge-config: default.isolate = true
contract PingPongModuleTest is NewModulesBase {
    PingPongModule pp;
    uint32 ppId;
    HookTokenV2 t;
    PoolKey key;
    MultiSwapper multi;

    uint256 constant BIG = 20 ether; // ~0.4% of supply at the graduation price (min trade: 0.1%)
    uint256 constant DUST = 0.05 ether;
    uint32 constant TIMEOUT = 600;

    function setUp() public override {
        super.setUp();
        pp = new PingPongModule(address(hook));
        ppId = modules.addModule(address(pp), '{"name":"Ping pong"}');
        // the curve plays ping pong too: buys a timeout apart (each one frees the turn for the next)
        t = _launch(_one(ppId), _oneCfg(abi.encode(PingPongModule.Config(10, TIMEOUT))), 0);
        key = _graduateN(t, 40, TIMEOUT);
        multi = new MultiSwapper(router);
        vm.deal(address(multi), 100 ether);
        // the graduating buy was counted: the pool opens on sell's turn. One sell hands it to the buyers.
        (, bool buys,) = pp.turn(address(t));
        assertFalse(buys);
        address h = _holder(0);
        _routerSell(h, t, t.balanceOf(h) / 10);
    }

    function _turn() internal view returns (bool free, bool buys) {
        (free, buys,) = pp.turn(address(t));
    }

    /// H-1 PoC: a direct PoolManager sell of 5M tokens with a price limit one step past spot fills ~2 wei,
    /// but modules saw the requested 5M and flipped the turn. Every swap must now fill completely.
    function test_partialFillDustSellCantFlipTheTurn() public {
        (bool free, bool buys) = _turn();
        assertFalse(free);
        assertTrue(buys); // buy's turn: a counted sell would flip nothing, but a sell isn't even allowed...
        vm.warp(vm.getBlockTimestamp() + TIMEOUT); // ...so free the turn: now any counted trade sets it
        address h = _holder(0);
        vm.prank(h);
        t.transfer(address(agg), 5_000_000 ether);
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(IPoolManager(address(PM)), _id(key));
        try agg.swapWithLimit(key, false, -int256(5_000_000 ether), sqrtP + 1) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, AvaxHookV2.PartialFillNotAllowed.selector));
        }
        (free,) = _turn();
        assertTrue(free); // untouched
        // a full-fill sell of the same size through the same aggregator still counts
        agg.swap(key, false, -int256(5_000_000 ether));
        (free, buys) = _turn();
        assertFalse(free);
        assertTrue(buys);
    }

    function test_capabilities() public view {
        assertEq(pp.capabilities(), ModuleCaps.AFTER_SWAP | ModuleCaps.BLOCKS_SELLS);
        assertEq(pp.conflictGroups(), ModuleCaps.GROUP_TURN);
    }

    /// On the curve: the first trade is a buy, then buys and sells take turns.
    function test_curveTurns() public {
        HookTokenV2 t2 = _launch(_one(ppId), _oneCfg(abi.encode(PingPongModule.Config(10, TIMEOUT))), 0);
        (bool free, bool buys,) = pp.turn(address(t2));
        assertFalse(free);
        assertTrue(buys);
        vm.prank(alice);
        pad.buy{value: 20 ether}(address(t2), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PingPongModule.NotYourTurn.selector, false, vm.getBlockTimestamp() + TIMEOUT));
        pad.buy{value: 20 ether}(address(t2), 0);
        uint256 bal = t2.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t2), bal / 2, 0);
        vm.prank(alice);
        vm.expectRevert();
        pad.sell(address(t2), bal / 4, 0);
        vm.prank(bob);
        pad.buy{value: 20 ether}(address(t2), 0);
    }

    function test_firstTurnFreesAfterTimeoutFromLaunch() public {
        HookTokenV2 t2 = _launch(_one(ppId), _oneCfg(abi.encode(PingPongModule.Config(10, TIMEOUT))), 0);
        (,, uint256 freeAt) = pp.turn(address(t2));
        assertEq(freeAt, vm.getBlockTimestamp() + TIMEOUT);
        vm.warp(freeAt);
        (bool free,,) = pp.turn(address(t2));
        assertTrue(free);
    }

    function test_alternation() public {
        address h = _holder(0);
        uint256 hb = t.balanceOf(h);
        uint256 a = _routerBuy(alice, t, BIG); // ping
        _buyReverts(bob, t, BIG); // two buys in a row
        _routerSell(h, t, hb / 10); // pong (0.1% of supply or more)
        assertGe(hb / 10, pp.minTrade(address(t)));
        _sellReverts(alice, t, a / 2); // two sells in a row
        _routerBuy(bob, t, BIG);
        _routerSell(alice, t, a);
    }

    /// Dust on the side whose turn it is goes through without flipping the turn; dust on the wrong side
    /// is refused like any trade.
    function test_dustDoesNotFlipOrSneak() public {
        uint256 a = _routerBuy(alice, t, BIG); // sell's turn
        uint256 dustSell = pp.minTrade(address(t)) / 4;
        _routerSell(alice, t, dustSell);
        _routerSell(alice, t, dustSell);
        (, bool buys) = _turn();
        assertFalse(buys); // still sell's turn
        _buyReverts(bob, t, DUST); // a dust buy can't steal the turn either
        address h = _holder(0);
        _routerSell(h, t, t.balanceOf(h) / 10); // the real pong
        (, buys) = _turn();
        assertTrue(buys);
        uint256 b = _routerBuy(bob, t, DUST); // dust buy on buy's turn: allowed, no flip
        assertLt(b, pp.minTrade(address(t)));
        (, buys) = _turn();
        assertTrue(buys);
        _sellReverts(alice, t, dustSell);
        assertGt(a, 0);
    }

    function test_turnFreesAfterTimeout() public {
        uint256 a = _routerBuy(alice, t, BIG);
        (,, uint256 freeAt) = pp.turn(address(t));
        assertEq(freeAt, block.timestamp + TIMEOUT);
        vm.warp(freeAt - 1);
        _buyReverts(bob, t, BIG);
        vm.warp(freeAt);
        (bool free,) = _turn();
        assertTrue(free);
        _routerBuy(bob, t, DUST); // free turn: a dust buy is fine and changes nothing
        (free,) = _turn();
        assertTrue(free);
        _routerBuy(bob, t, BIG); // a counted buy sets the turn again: sell's
        (bool f2, bool buys) = _turn();
        assertFalse(f2);
        assertFalse(buys);
        _buyReverts(carol, t, BIG);
        _routerSell(alice, t, a);
    }

    function test_oneSwapPerTransaction() public {
        bytes memory err;
        // buy then sell in one transaction: refused even though the turns would line up
        try multi.buyThenSell(address(t), BIG) {
            fail();
        } catch (bytes memory e) {
            err = e;
        }
        assertTrue(_has(err, PingPongModule.OneSwapPerTx.selector));
        // the same trades in two transactions are fine
        _routerBuy(address(multi), t, BIG);
        address h = _holder(1);
        _routerSell(h, t, t.balanceOf(h) / 10);
    }

    function test_aggregatorsPlayToo() public {
        agg.swap(key, true, -int256(BIG)); // a counted buy from anyone
        _buyReverts(alice, t, BIG);
        vm.expectRevert();
        agg.swap(key, true, -int256(BIG));
    }

    function test_configBounds() public {
        vm.expectRevert();
        pp.validateConfig(abi.encode(PingPongModule.Config(0, 600)));
        vm.expectRevert();
        pp.validateConfig(abi.encode(PingPongModule.Config(501, 600)));
        vm.expectRevert();
        pp.validateConfig(abi.encode(PingPongModule.Config(10, 59)));
        vm.expectRevert();
        pp.validateConfig(abi.encode(PingPongModule.Config(10, 7 days + 1)));
        pp.validateConfig(abi.encode(PingPongModule.Config(500, 60)));
    }
}
