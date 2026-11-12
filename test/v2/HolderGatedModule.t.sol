// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HolderGatedModule} from "../../contracts/v2/modules/HolderGatedModule.sol";
import {MockRewardToken} from "./NewModulesBase.t.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract HolderGatedModuleTest is ListsAccessBase {
    HolderGatedModule hg;
    uint32 hgId;
    MockRewardToken gateT;
    uint256 constant MIN = 100 ether;

    function setUp() public override {
        super.setUp();
        hg = new HolderGatedModule(address(hook));
        hgId = modules.addModule(address(hg), '{"name":"Holder-gated"}');
        gateT = new MockRewardToken();
        _allowQuote(address(gateT));
        for (uint256 i; i < 120; ++i) gateT.mint(_holder(i), MIN);
        gateT.mint(alice, MIN);
    }

    function _cfg(address g, uint256 min, uint32 d) internal pure returns (bytes memory) {
        return abi.encode(HolderGatedModule.Config(g, min, d));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(hg.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY);
        assertEq(hg.conflictGroups(), ModuleCaps.GROUP_RECEIVER_LIST);
        vm.expectRevert();
        hg.validateConfig(_cfg(address(0), MIN, 0));
        vm.expectRevert();
        hg.validateConfig(_cfg(address(gateT), 0, 0));
        vm.expectRevert();
        hg.validateConfig(_cfg(address(gateT), MIN, 365 days + 1));
        hg.validateConfig(_cfg(address(gateT), MIN, 365 days));
        // gate token without code / without balanceOf: the launch reverts
        _launchReverts(hgId, _cfg(makeAddr("eoa"), MIN, 0));
        _launchReverts(hgId, _cfg(address(modules), MIN, 0));
        // M-3: any ERC-20 that is neither a v2 token nor an allowed quote is refused
        _launchReverts(hgId, _cfg(address(new MockRewardToken()), MIN, 0));
    }

    function test_curveGate() public {
        HookTokenV2 t = _launch(_one(hgId), _oneCfg(_cfg(address(gateT), MIN, 0)), 0);
        _curveBuyReverts(bob, t, 1 ether); // no gate token
        _curveBuy(alice, t, 1 ether);
        _curveBuy(creator, t, 1 ether); // creator exempt
        assertTrue(hg.canReceive(address(t), alice));
        assertFalse(hg.canReceive(address(t), bob));
        // curve sell always works, even after the seller lost the gate
        vm.prank(alice);
        gateT.transfer(bob, MIN);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t), bal, 0);
        assertEq(t.balanceOf(alice), 0);
        // and now bob qualifies
        _curveBuy(bob, t, 1 ether);
    }

    function test_poolGate_routerAggTransfersAndExpiry() public {
        HookTokenV2 t = _launch(_one(hgId), _oneCfg(_cfg(address(gateT), MIN, 1 days)), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        _buyReverts(bob, t, 1 ether);
        uint256 got = _routerBuy(alice, t, 1 ether);
        // aggregators on the PoolManager: refused with RouterOnly while the gate applies, even holding the gate
        // (claims bypass guard, 2026-11-12)
        _aggSwapRouterOnly(key, true, -int256(1 ether));
        gateT.mint(address(agg), MIN);
        _aggSwapRouterOnly(key, true, -int256(1 ether));
        // transfers to non-holders refused, to holders fine
        _sendReverts(t, alice, bob, got / 2);
        _send(t, alice, _holder(1), got / 4);
        _send(t, alice, creator, got / 8);
        // sells always work
        _routerSell(_holder(1), t, t.balanceOf(_holder(1)));
        // window ends
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _routerBuy(bob, t, 1 ether);
        _send(t, bob, carol, 1 ether);
        _aggBuy(key, 1 ether); // direct PoolManager buys work again
        (address g, uint256 m, uint256 until) = hg.gate(address(t));
        assertEq(g, address(gateT));
        assertEq(m, MIN);
        assertEq(until, hook.openedAt(pad.poolKey(address(t)).toId()) + 1 days);
    }

    function test_gateTokenRevertingReadsAsZero() public {
        HookTokenV2 t = _launch(_one(hgId), _oneCfg(_cfg(address(gateT), MIN, 0)), 0);
        vm.mockCallRevert(address(gateT), abi.encodeWithSelector(gateT.balanceOf.selector, alice), "x");
        _curveBuyReverts(alice, t, 1 ether);
        vm.clearMockedCalls();
        _allowQuote(address(gateT));
        _curveBuy(alice, t, 1 ether);
    }

    function testFuzz_threshold(uint256 held) public {
        held = bound(held, 0, 2 * MIN);
        HookTokenV2 t = _launch(_one(hgId), _oneCfg(_cfg(address(gateT), MIN, 0)), 0);
        gateT.mint(carol, held);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        if (held < MIN) vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);
    }
}
