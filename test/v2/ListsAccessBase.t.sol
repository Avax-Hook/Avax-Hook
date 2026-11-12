// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

/// Helpers shared by the "lists and access" module tests (holder-gated, alliances, blocklist, allowlist,
/// dex-only, p2p-only, plague).
abstract contract ListsAccessBase is NewModulesBase {
    /// A launch with one module that must revert (bad context in onRegister).
    function _launchReverts(uint32 id, bytes memory cfg) internal {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "King";
        a.symbol = "KING";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _one(id);
        a.moduleConfigs = _oneCfg(cfg);
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        vm.expectRevert();
        pad.launch{value: fee}(a);
    }

    /// Makes the live QuoteRegistry report `t` as an allowed quote (rules accept v2 tokens and allowed quotes
    /// as foreign tokens).
    function _allowQuote(address t) internal {
        vm.mockCall(address(LIVE_QUOTES), abi.encodeWithSelector(LIVE_QUOTES.quotes.selector, t), abi.encode(true, uint8(18), address(0)));
    }

    function _target(HookTokenV2 t) internal view returns (uint256) {
        return uint256(pad.getLaunch(address(t)).target);
    }

    /// The creator fills the whole curve in one buy (the excess is refunded) and the pool opens.
    function _creatorGraduates(HookTokenV2 t) internal returns (PoolKey memory key) {
        uint256 amt = _target(t) * 2;
        vm.deal(creator, creator.balance + amt);
        vm.prank(creator);
        pad.buy{value: amt}(address(t), 0);
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        key = pad.poolKey(address(t));
    }

    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
    }

    function _curveBuyReverts(address who, HookTokenV2 t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        vm.expectRevert();
        pad.buy{value: amt}(address(t), 0);
    }

    /// Direct PoolManager buy (no router: trader unknown), tokens land on the DirectSwapper contract.
    function _aggBuy(PoolKey memory key, uint256 amt) internal {
        agg.swap(key, true, -int256(amt));
    }

    function _send(HookTokenV2 t, address from, address to, uint256 amt) internal {
        vm.prank(from);
        t.transfer(to, amt);
    }

    function _sendReverts(HookTokenV2 t, address from, address to, uint256 amt) internal {
        vm.prank(from);
        vm.expectRevert();
        t.transfer(to, amt);
    }
}
