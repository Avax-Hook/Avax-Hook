// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../../contracts/v2/interfaces/IHookModule.sol";
import {BlueprintRegistryV1} from "../../../contracts/v2/blueprints/BlueprintRegistryV1.sol";
import {RoyaltyModule, IBlueprintRoyalty} from "../../../contracts/v2/modules/RoyaltyModule.sol";
import {TitheModule} from "../../../contracts/v2/modules/TitheModule.sol";
import {NewModulesBase} from "../NewModulesBase.t.sol";

contract BlueprintsTest is NewModulesBase {
    BlueprintRegistryV1 bps;
    RoyaltyModule roy;
    TitheModule ti;
    uint32 royId;
    uint32 tiId;
    address author = makeAddr("author");
    address cause = makeAddr("cause");

    function setUp() public override {
        super.setUp();
        bps = new BlueprintRegistryV1(address(this));
        roy = new RoyaltyModule(address(hook), IBlueprintRoyalty(address(bps)), 0);
        royId = modules.addModule(address(roy), '{"name":"Royalty"}');
        bps.setRecorder(address(roy), true);
        ti = new TitheModule(address(hook));
        tiId = modules.addModule(address(ti), '{"name":"Tithe"}');
    }

    function _spec() internal view returns (bytes memory) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = tiId;
        cfgs[0] = abi.encode(TitheModule.Config(cause, 100));
        return abi.encode(ids, cfgs, uint16(50), uint24(3_000));
    }

    function _publish(uint16 royaltyBps) internal returns (uint32 id) {
        vm.prank(author);
        id = bps.publish("Cause coin", "ipfs://x", 0, _spec(), royaltyBps, 0);
    }

    /// Launch with the blueprint's modules + RoyaltyModule, as the app does.
    function _launchWith(uint32 bpId, address payee, uint16 share) internal returns (HookTokenV2 t) {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (tiId, royId);
        cfgs[0] = abi.encode(TitheModule.Config(cause, 100));
        cfgs[1] = abi.encode(RoyaltyModule.Config(bpId, payee, share));
        t = _launch(ids, cfgs, 50);
    }

    function _launchWithReverts(uint32 bpId, address payee, uint16 share) internal {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (tiId, royId);
        cfgs[0] = abi.encode(TitheModule.Config(cause, 100));
        cfgs[1] = abi.encode(RoyaltyModule.Config(bpId, payee, share));
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "King";
        a.symbol = "KING";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3_000});
        a.moduleIds = ids;
        a.moduleConfigs = cfgs;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        vm.expectRevert();
        pad.launch{value: fee}(a);
    }

    // ---------------------------------------------------------------- registry

    function test_publishAndRead() public {
        uint32 id = _publish(25);
        BlueprintRegistryV1.Blueprint memory b = bps.blueprint(id);
        assertEq(b.author, author);
        assertEq(b.royaltyBps, 25);
        assertEq(b.specHash, keccak256(_spec()));
        assertEq(bps.specOf(id), _spec());
        assertEq(bps.count(), 1);
        assertEq(bps.byAuthor(author)[0], id);
        (uint32[] memory ids,) = bps.page(0, 10);
        assertEq(ids[0], id);
    }

    function test_publishLimits() public {
        vm.startPrank(author);
        vm.expectRevert(BlueprintRegistryV1.BadArgs.selector);
        bps.publish("x", "", 0, _spec(), 51, 0); // royalty above 0.5%
        vm.expectRevert(BlueprintRegistryV1.BadArgs.selector);
        bps.publish("", "", 0, _spec(), 0, 0); // no name
        vm.expectRevert(BlueprintRegistryV1.BadArgs.selector);
        bps.publish("x", "", 2, _spec(), 0, 0); // unknown profile
        vm.expectRevert(BlueprintRegistryV1.UnknownBlueprint.selector);
        bps.publish("x", "", 0, _spec(), 0, 7); // remix of nothing
        // 8 modules + the royalty slot would be 9
        uint32[] memory eight = new uint32[](8);
        bytes[] memory cfgs = new bytes[](8);
        vm.expectRevert(BlueprintRegistryV1.BadArgs.selector);
        bps.publish("x", "", 0, abi.encode(eight, cfgs, uint16(0), uint24(0)), 10, 0);
        bps.publish("x", "", 0, abi.encode(eight, cfgs, uint16(0), uint24(0)), 0, 0); // no royalty: 8 is fine
        vm.stopPrank();
    }

    function test_hideRules() public {
        uint32 id = _publish(25);
        vm.prank(alice);
        vm.expectRevert(BlueprintRegistryV1.NotAuthor.selector);
        bps.setHidden(id, true);
        vm.prank(author);
        bps.setHidden(id, true);
        vm.prank(author);
        vm.expectRevert(BlueprintRegistryV1.NotAuthor.selector);
        bps.setHidden(id, false); // only the Safe unhides
        bps.setHidden(id, false);
        assertFalse(bps.blueprint(id).hidden);
    }

    function test_onlyRecorderCounts() public {
        uint32 id = _publish(25);
        vm.expectRevert(BlueprintRegistryV1.NotRecorder.selector);
        vm.prank(alice);
        bps.recordUse(id, bytes32(0), address(0));
    }

    // ---------------------------------------------------------------- royalty module

    function test_royaltyPaidOnCurveAndPoolAndCounted() public {
        uint32 id = _publish(25); // 0.25%
        assertEq(roy.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        HookTokenV2 t = _launchWith(id, author, 25);
        assertEq(bps.blueprint(id).uses, 1);

        vm.prank(alice);
        pad.buy{value: 10 ether}(address(t), 0);
        assertEq(hook.claimable(author, NATIVE), 0.025 ether, "curve buy royalty");

        PoolKey memory key = _graduateN(t, 40, 0);
        uint256 c0 = hook.claimable(author, NATIVE);
        uint256 got = _routerBuy(bob, t, 4 ether);
        assertEq(hook.claimable(author, NATIVE) - c0, 0.01 ether, "pool buy royalty");
        uint256 c1 = hook.claimable(author, NATIVE);
        _routerSell(bob, t, got);
        assertGt(hook.claimable(author, NATIVE), c1, "pool sell royalty");
        agg.swap(key, true, -int256(1 ether));

        uint256 owed = hook.claimable(author, NATIVE);
        vm.prank(author);
        hook.claim(NATIVE, author);
        assertEq(author.balance, owed);
    }

    function test_cannotFakeAuthorOrShare() public {
        uint32 id = _publish(25);
        _launchWithReverts(id, alice, 25); // wrong payee
        _launchWithReverts(id, author, 50); // wrong share
        _launchWithReverts(id + 1, author, 25); // unknown blueprint
    }

    function test_hiddenBlueprintNotLaunchable() public {
        uint32 id = _publish(25);
        HookTokenV2 t = _launchWith(id, author, 25);
        bps.setHidden(id, true);
        _launchWithReverts(id, author, 25);
        // existing launches keep paying
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t), 0);
        assertGt(hook.claimable(author, NATIVE), 0);
    }

    function test_wrongProfileRefused() public {
        vm.prank(author);
        uint32 id = bps.publish("Pool rules", "", 1, _spec(), 25, 0); // made for the pools profile
        _launchWithReverts(id, author, 25);
    }

    function test_unapprovedModuleCantRecord() public {
        uint32 id = _publish(25);
        bps.setRecorder(address(roy), false);
        _launchWithReverts(id, author, 25);
    }
}
