// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {BeaconModule} from "../../contracts/v2/modules/BeaconModule.sol";
import {EntangledModule} from "../../contracts/v2/modules/EntangledModule.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract EntangledModuleTest is NewModulesBase {
    BeaconModule bc;
    EntangledModule en;
    uint32 bcId;
    uint32 enId;
    HookTokenV2 beaconT;
    HookTokenV2 t;
    PoolKey key;

    event Unlocked(address indexed token, address indexed beaconToken, uint256 beaconAthUsd, bool byTimeout);

    function setUp() public override {
        super.setUp();
        bc = new BeaconModule(address(hook));
        en = new EntangledModule(address(hook));
        bcId = modules.addModule(address(bc), '{"name":"Beacon"}');
        enId = modules.addModule(address(en), '{"name":"Entangled"}');
        (beaconT,) = _launchOne(bcId, "");
    }

    function _cfg(address b, uint64 usd, uint32 maxLock) internal pure returns (bytes memory) {
        return abi.encode(EntangledModule.Config(b, usd, maxLock));
    }

    /// One observation of the beacon in a later block.
    function _poke() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 4 minutes);
        _routerBuy(carol, beaconT, 0.01 ether);
    }

    /// Holds the beacon's current price long enough to count as its ATH (see BeaconModule).
    function _sustain() internal {
        for (uint256 i; i < 6; i++) _poke();
    }

    function test_capabilities() public view {
        assertEq(en.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS);
        assertEq(en.conflictGroups(), ModuleCaps.GROUP_SELL_LOCK);
    }

    /// The curve and the pool are both locked until the beacon's ATH reaches the target.
    function test_lockedUntilBeaconHitsTarget() public {
        _mockAvaxUsd(20e18);
        _sustain();
        uint256 m0 = bc.athUsd(address(beaconT));
        uint64 target = uint64((m0 * 3) / 2 / 1e18); // 1.5x the beacon's market cap now
        t = _launch(_one(enId), _oneCfg(_cfg(address(beaconT), target, 30 days)), 0);
        (, address b) = en.link(address(t));
        assertEq(b, address(bc));

        // locked on the curve
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntangledModule.Locked.selector, m0, uint256(target) * 1e18, vm.getBlockTimestamp() + 30 days));
        pad.buy{value: 1 ether}(address(t), 0);

        // a flash pump of the beacon doesn't count
        uint256 got = _routerBuy(bob, beaconT, 1000 ether);
        _routerSell(bob, beaconT, got);
        _poke();
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);

        // a pump that holds does
        _routerBuy(bob, beaconT, 1000 ether);
        _sustain();
        assertGe(bc.athUsd(address(beaconT)), uint256(target) * 1e18);
        (bool open,,,) = en.status(address(t));
        assertTrue(open);
        vm.expectEmit(true, true, false, false, address(en));
        emit Unlocked(address(t), address(beaconT), 0, false);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t), 0);

        // unlocked for good, whatever the beacon does next: the curve fills, the pool trades both ways
        _routerSell(bob, beaconT, beaconT.balanceOf(bob));
        key = _graduateN(t, 40, 0);
        uint256 a = _routerBuy(alice, t, 1 ether);
        _routerSell(alice, t, a);
        address h = _holder(0);
        _routerSell(h, t, 1 ether);
        vm.prank(h);
        t.transfer(carol, 1 ether);
        agg.swap(key, true, -int256(1 ether));
    }

    function test_safetyValveUnlocksAfterMaxLock() public {
        t = _launch(_one(enId), _oneCfg(_cfg(address(beaconT), 1e12, 1 days)), 0);
        uint256 launched = vm.getBlockTimestamp();
        vm.warp(launched + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1 ether}(address(t), 0);
        vm.warp(launched + 1 days);
        vm.expectEmit(true, true, false, false, address(en));
        emit Unlocked(address(t), address(beaconT), 0, true);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t), 0);
        _graduateN(t, 40, 0);
        _routerBuy(alice, t, 1 ether);
    }

    function test_beaconMustHaveTheBeaconModule() public {
        (HookTokenV2 plain,) = _launchOne(kothId, _kothCfg(1 ether, 500, 50, 0, false));
        uint32[] memory ids = _one(enId);
        bytes[] memory cfgs = _oneCfg(_cfg(address(plain), 100_000, 1 days));
        vm.expectRevert(EntangledModule.NoBeacon.selector);
        this.launchExt(ids, cfgs);
        cfgs[0] = _cfg(alice, 100_000, 1 days); // not a launched token at all
        vm.expectRevert(EntangledModule.NoBeacon.selector);
        this.launchExt(ids, cfgs);
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs) external {
        _launch(ids, cfgs, 0);
    }

    function test_configBounds() public {
        vm.expectRevert();
        en.validateConfig(_cfg(address(0), 100_000, 1 days));
        vm.expectRevert();
        en.validateConfig(_cfg(address(beaconT), 999, 1 days));
        vm.expectRevert();
        en.validateConfig(_cfg(address(beaconT), 100_000, 1 hours - 1));
        vm.expectRevert();
        en.validateConfig(_cfg(address(beaconT), 100_000, 365 days + 1));
        en.validateConfig(_cfg(address(beaconT), 1000, 1 hours));
    }
}
