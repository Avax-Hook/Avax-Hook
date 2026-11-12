// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {PlagueModule} from "../../contracts/v2/modules/PlagueModule.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract PlagueModuleTest is ListsAccessBase {
    PlagueModule pl;
    uint32 plId;
    uint128 constant MIN_INFECT = 1_000 ether;

    function setUp() public override {
        super.setUp();
        pl = new PlagueModule(address(hook));
        plId = modules.addModule(address(pl), '{"name":"Plague"}');
    }

    function _cfg(uint128 m, uint32 d) internal pure returns (bytes memory) {
        return abi.encode(PlagueModule.Config(m, d));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(pl.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY);
        assertEq(pl.conflictGroups(), ModuleCaps.GROUP_RECEIVER_LIST);
        vm.expectRevert();
        pl.validateConfig(_cfg(0, 0));
        vm.expectRevert();
        pl.validateConfig(_cfg(uint128(SUPPLY / 100 + 1), 0));
        vm.expectRevert();
        pl.validateConfig(_cfg(MIN_INFECT, 365 days + 1));
        pl.validateConfig(_cfg(MIN_INFECT, 365 days));
    }

    function test_curveBuyersInfected_poolBuysNeedInfection() public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(_cfg(MIN_INFECT, 0)), 0);
        assertTrue(pl.infected(address(t), creator));
        assertFalse(pl.infected(address(t), alice));
        assertTrue(pl.canBuy(address(t), alice)); // curve: free
        _curveBuy(alice, t, 1 ether);
        assertTrue(pl.infected(address(t), alice));
        PoolKey memory key = _graduateN(t, 40, 0);
        assertTrue(pl.infected(address(t), _holder(0)));
        // pool: uninfected refused (router and aggregator), infected fine
        assertFalse(pl.canBuy(address(t), bob));
        _buyReverts(bob, t, 1 ether);
        vm.expectRevert();
        _aggBuy(key, 1 ether);
        _routerBuy(alice, t, 1 ether);
        // a small transfer doesn't infect, a big one does
        _send(t, alice, bob, MIN_INFECT - 1);
        assertFalse(pl.infected(address(t), bob));
        _buyReverts(bob, t, 1 ether);
        _send(t, alice, bob, MIN_INFECT);
        assertTrue(pl.infected(address(t), bob));
        _routerBuy(bob, t, 1 ether);
        // chain: bob infects carol
        _send(t, bob, carol, MIN_INFECT);
        assertTrue(pl.infected(address(t), carol));
        // an uninfected sender can't infect
        address dave = makeAddr("dave");
        address erin = makeAddr("erin");
        _send(t, carol, dave, MIN_INFECT - 1);
        _sendReverts(t, dave, erin, MIN_INFECT - 1); // uninfected -> uninfected wallet refused
        assertFalse(pl.infected(address(t), erin));
        // sells always work, even uninfected
        _routerSell(dave, t, t.balanceOf(dave));
    }

    function test_contractsNeverCatchIt() public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(_cfg(MIN_INFECT, 0)), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        _send(t, _holder(0), address(agg), MIN_INFECT * 2);
        assertFalse(pl.infected(address(t), address(agg)));
        vm.expectRevert();
        _aggBuy(key, 1 ether);
    }

    function test_plagueEnds() public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(_cfg(MIN_INFECT, 1 days)), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        _buyReverts(bob, t, 1 ether);
        (, uint256 until) = pl.plague(address(t));
        vm.warp(until);
        assertTrue(pl.canBuy(address(t), bob));
        _routerBuy(bob, t, 1 ether);
        _aggBuy(key, 1 ether);
    }

    function testFuzz_infectThreshold(uint128 amt) public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(_cfg(MIN_INFECT, 0)), 0);
        _graduateN(t, 40, 0);
        amt = uint128(bound(amt, 1, t.balanceOf(_holder(0))));
        _send(t, _holder(0), bob, amt);
        assertEq(pl.infected(address(t), bob), amt >= MIN_INFECT);
    }
}
