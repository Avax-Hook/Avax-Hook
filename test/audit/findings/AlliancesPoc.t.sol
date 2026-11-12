// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AlliancesModule} from "../../../contracts/v2/modules/AlliancesModule.sol";
import {MockRewardToken} from "../../v2/NewModulesBase.t.sol";
import {ListsAccessBase} from "../../v2/ListsAccessBase.t.sol";

/// Regression (was a finding): anyone could bar a victim from buying/receiving an Alliances token by SENDING
/// the victim `rivalMin` of a rival token, and `rivalMin` could be 1 wei. Each rival's threshold is now at
/// least 0.1% of the rival's supply, so dust no longer bars anyone; pushing the full threshold still does
/// (documented), at the cost of giving the victim 0.1% of the rival's supply.
contract AlliancesPoc is ListsAccessBase {
    AlliancesModule am;
    uint32 amId;
    MockRewardToken rival;
    uint256 constant RIVAL_SUPPLY = 1_000_000_000 ether;

    function setUp() public override {
        super.setUp();
        am = new AlliancesModule(address(hook));
        amId = modules.addModule(address(am), '{"name":"Alliances"}');
        rival = new MockRewardToken();
        rival.mint(address(0xbeef), RIVAL_SUPPLY);
        _allowQuote(address(rival));
    }

    function test_dustNoLongerBlocksVictim() public {
        address[] memory none = new address[](0);
        address[] memory rv = new address[](1);
        rv[0] = address(rival);
        // rivalMin = 1 wei: raised to 0.1% of the rival's supply
        HookTokenV2 t = _launch(_one(amId), _oneCfg(abi.encode(AlliancesModule.Config(0, 1, 1, none, rv))), 0);
        uint256 floor = RIVAL_SUPPLY / 1_000;
        assertEq(am.rivalMinOf(address(t), address(rival)), floor);

        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        rival.mint(attacker, floor);
        vm.prank(attacker);
        rival.transfer(victim, floor - 1); // just under the floor: no effect
        _curveBuy(victim, t, 1 ether);
        (address barredBy,) = am.standing(address(t), victim);
        assertEq(barredBy, address(0));

        // the full threshold still bars (documented limit), at the cost of 0.1% of the rival's supply
        vm.prank(attacker);
        rival.transfer(victim, 1);
        _curveBuyReverts(victim, t, 1 ether);
    }

    function test_rivalMinAboveFloorIsKept() public {
        address[] memory none = new address[](0);
        address[] memory rv = new address[](1);
        rv[0] = address(rival);
        uint256 big = RIVAL_SUPPLY / 100;
        HookTokenV2 t = _launch(_one(amId), _oneCfg(abi.encode(AlliancesModule.Config(0, 1, big, none, rv))), 0);
        assertEq(am.rivalMinOf(address(t), address(rival)), big);
    }
}
