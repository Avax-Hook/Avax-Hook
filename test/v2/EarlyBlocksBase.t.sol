// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

/// Helpers for the package-3 module tests (early blocks, timing and physics).
abstract contract EarlyBlocksBase is NewModulesBase {
    /// Launch by `creator` with a dev buy of `devBuy` AVAX in the launch transaction.
    function _launchWithDevBuy(uint32[] memory ids, bytes[] memory cfgs, uint256 devBuy) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Early";
        a.symbol = "EARLY";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = ids;
        a.moduleConfigs = cfgs;
        a.devBuy = devBuy;
        uint256 fee = pad.creationFee();
        vm.deal(creator, creator.balance + fee + devBuy);
        vm.prank(creator);
        t = HookTokenV2(pad.launch{value: fee + devBuy}(a));
    }

    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
    }

    function _curveSell(address who, HookTokenV2 t, uint256 amt) internal {
        vm.startPrank(who);
        t.approve(address(pad), amt);
        pad.sell(address(t), amt, 0);
        vm.stopPrank();
    }
}
