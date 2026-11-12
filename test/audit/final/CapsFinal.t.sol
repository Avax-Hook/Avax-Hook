// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AutoLpModule} from "../../../contracts/v2/modules/AutoLpModule.sol";
import {HolderVestingModule} from "../../../contracts/v2/modules/HolderVestingModule.sol";
import {ConvictionCapModule} from "../../../contracts/v2/modules/ConvictionCapModule.sol";
import {GraduatedSellCapModule} from "../../../contracts/v2/modules/GraduatedSellCapModule.sol";
import {GrudgeModule} from "../../../contracts/v2/modules/GrudgeModule.sol";
import {ListsAccessBase} from "../../v2/ListsAccessBase.t.sol";

/// forge-config: default.isolate = true
contract CapsFinalAutoLpTest is ListsAccessBase {
    AutoLpModule autoLp;
    uint32 alpId;

    function setUp() public override {
        super.setUp();
        autoLp = new AutoLpModule(address(hook));
        alpId = modules.addModule(address(autoLp), '{"name":"Auto-LP"}');
    }

    function _with(address m, string memory name, bytes memory cfg) internal returns (HookTokenV2 t, PoolKey memory key) {
        uint32 id = modules.addModule(m, name);
        uint32[] memory ids = new uint32[](2);
        (ids[0], ids[1]) = (id, alpId);
        bytes[] memory cfgs = new bytes[](2);
        (cfgs[0], cfgs[1]) = (cfg, abi.encode(AutoLpModule.Config(200, 1 ether)));
        t = _launch(ids, cfgs, 0);
        key = _graduateN(t, 40, 0);
    }

    function _compound(PoolKey memory key, HookTokenV2 t) internal returns (bool ok) {
        vm.roll(vm.getBlockNumber() + 61);
        _routerBuy(_holder(0), t, 0.01 ether);
        vm.roll(vm.getBlockNumber() + 30);
        try autoLp.compound(key) {
            ok = true;
        } catch (bytes memory err) {
            console2.logBytes(err);
        }
    }

    function test_caps_vestingCompoundWorks() public {
        HolderVestingModule hv = new HolderVestingModule(address(hook));
        (HookTokenV2 t, PoolKey memory key) =
            _with(address(hv), '{"name":"HV"}', abi.encode(HolderVestingModule.Config(0, 0, 30 days, 1_000, 30 days)));
        assertTrue(_compound(key, t), "fixed: Auto-LP's claims don't vest, its add isn't 'below locked'");
        (uint256 locked,,,) = hv.vestingOf(address(t), address(autoLp));
        assertEq(locked, 0);
    }

    function test_caps_convictionCompoundWorks() public {
        ConvictionCapModule cc = new ConvictionCapModule(address(hook));
        uint32 id = modules.addModule(address(cc), '{"name":"CC"}');
        uint32[] memory ids = new uint32[](2);
        (ids[0], ids[1]) = (id, alpId);
        bytes[] memory cfgs = new bytes[](2);
        (cfgs[0], cfgs[1]) =
            (abi.encode(ConvictionCapModule.Config(10, 1, 30 days, 10, 0)), abi.encode(AutoLpModule.Config(500, 50 ether)));
        HookTokenV2 t = _launch(ids, cfgs, 0);
        PoolKey memory key = _graduateCapped(t, 900_000 ether, 0);
        assertTrue(_compound(key, t), "fixed: Auto-LP's claim from the PoolManager is not a capped buy");
    }

    function test_caps_gradSellCompoundWorks() public {
        GraduatedSellCapModule gs = new GraduatedSellCapModule(address(hook));
        (HookTokenV2 t, PoolKey memory key) =
            _with(address(gs), '{"name":"GS"}', abi.encode(GraduatedSellCapModule.Config(1, 1, 2, 1, 0)));
        assertTrue(_compound(key, t), "fixed: Auto-LP's liquidity add is not a capped sell");
    }

    function test_caps_grudgeCompoundWorks() public {
        GrudgeModule gm = new GrudgeModule(address(hook));
        (HookTokenV2 t, PoolKey memory key) =
            _with(address(gm), '{"name":"GM"}', abi.encode(GrudgeModule.Config(1_000, 1 days, 30 days, 0, 0, 0)));
        bool ok1 = _compound(key, t);
        (, uint256 count,) = gm.grudgeOf(address(t), address(autoLp));
        assertTrue(ok1, "compound works");
        assertEq(count, 0, "Auto-LP is never grudged");
        assertTrue(_compound(key, t), "and keeps working");
    }
}
