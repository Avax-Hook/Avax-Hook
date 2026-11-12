// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {V1PortBase} from "./V1PortBase.t.sol";

contract LpRewardsModuleTest is V1PortBase {
    function test_donatesShareOfBuysToLiquidity() public {
        (HookTokenV2 t, PoolKey memory key) = _one(lpId, _lpCfg(500));
        (HookTokenV2 p,) = _plain();
        _routerBuy(bob, t, 10 ether);
        _routerBuy(bob, p, 10 ether);
        assertEq(lpRewards.rewardsOf(_id(key)).totalDonated, 0.5 ether);
        // the locked launch position collects the donation on top of its LP fees
        uint256 c0 = pad.claimable(creator, address(0));
        pad.collectLpFees(address(t));
        uint256 withRewards = pad.claimable(creator, address(0)) - c0;
        c0 = pad.claimable(creator, address(0));
        pad.collectLpFees(address(p));
        uint256 plain = pad.claimable(creator, address(0)) - c0;
        assertApproxEqAbs(withRewards - plain, 0.5 ether, 0.003 ether); // minus the LP fee on the donated part
        // sells donate nothing
        _routerSell(bob, t, t.balanceOf(bob));
        assertEq(lpRewards.rewardsOf(_id(key)).totalDonated, 0.5 ether);
    }

    function test_configBounds() public {
        vm.expectRevert();
        lpRewards.validateConfig(_lpCfg(0));
        vm.expectRevert();
        lpRewards.validateConfig(_lpCfg(1_001));
        lpRewards.validateConfig(_lpCfg(1_000));
    }
}
