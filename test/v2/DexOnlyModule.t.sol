// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {DexOnlyModule} from "../../contracts/v2/modules/DexOnlyModule.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract Vault {
    function send(HookTokenV2 t, address to, uint256 amt) external {
        t.transfer(to, amt);
    }
}

contract DexOnlyModuleTest is ListsAccessBase {
    DexOnlyModule dx;
    uint32 dxId;

    function setUp() public override {
        super.setUp();
        dx = new DexOnlyModule(address(hook));
        dxId = modules.addModule(address(dx), '{"name":"DEX-only"}');
    }

    function _cfg(uint32 d) internal pure returns (bytes memory) {
        return abi.encode(DexOnlyModule.Config(d));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(dx.capabilities(), ModuleCaps.ON_TRANSFER);
        assertEq(dx.conflictGroups(), ModuleCaps.GROUP_VENUE);
        vm.expectRevert();
        dx.validateConfig(_cfg(365 days + 1));
        dx.validateConfig(_cfg(0));
    }

    function test_swapsWork_walletSendsRefused() public {
        HookTokenV2 t = _launch(_one(dxId), _oneCfg(_cfg(0)), 0);
        _curveBuy(alice, t, 1 ether); // curve buys (from the launchpad) pass
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        pad.sell(address(t), half, 0); // curve sells pass
        PoolKey memory key = _graduateN(t, 40, 0);
        uint256 got = _routerBuy(bob, t, 1 ether);
        _aggBuy(key, 1 ether); // tokens land on a contract: fine
        assertTrue(dx.wouldRefuse(address(t), bob, carol));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DexOnlyModule.WalletToWallet.selector, bob, carol));
        t.transfer(carol, got / 2);
        // wallet -> contract and contract -> wallet pass
        Vault v = new Vault();
        _send(t, bob, address(v), got / 2);
        v.send(t, carol, got / 4);
        // sells always work (router and aggregator pulling from the wallet)
        _routerSell(carol, t, got / 4);
        vm.prank(bob);
        t.approve(address(agg), got / 4);
        agg.sellFrom(key, address(t), bob, got / 4);
    }

    function test_7702DelegatedCountsAsEoa() public {
        HookTokenV2 t = _launch(_one(dxId), _oneCfg(_cfg(0)), 0);
        _graduateN(t, 40, 0);
        uint256 got = _routerBuy(bob, t, 1 ether);
        vm.etch(carol, abi.encodePacked(hex"ef0100", address(0x1234)));
        assertTrue(dx.wouldRefuse(address(t), bob, carol));
        _sendReverts(t, bob, carol, got);
        vm.etch(carol, hex"60006000"); // real code: a contract
        _send(t, bob, carol, got);
    }

    function test_windowEnds() public {
        HookTokenV2 t = _launch(_one(dxId), _oneCfg(_cfg(1 days)), 0);
        _graduateN(t, 40, 0);
        uint256 got = _routerBuy(bob, t, 1 ether);
        _sendReverts(t, bob, carol, got);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertFalse(dx.wouldRefuse(address(t), bob, carol));
        _send(t, bob, carol, got);
    }
}
