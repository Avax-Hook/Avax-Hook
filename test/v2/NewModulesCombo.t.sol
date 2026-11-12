// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {MarketHoursBase, MarketHoursModule} from "../../contracts/v2/modules/MarketHoursModule.sol";
import {HotPotatoModule} from "../../contracts/v2/modules/HotPotatoModule.sol";
import {PingPongModule} from "../../contracts/v2/modules/PingPongModule.sol";
import {MomentumModule} from "../../contracts/v2/modules/MomentumModule.sol";
import {BreathingCapModule} from "../../contracts/v2/modules/BreathingCapModule.sol";
import {SlidingCapsModule} from "../../contracts/v2/modules/SlidingCapsModule.sol";
import {TitheModule} from "../../contracts/v2/modules/TitheModule.sol";
import {BeaconModule} from "../../contracts/v2/modules/BeaconModule.sol";
import {EntangledModule} from "../../contracts/v2/modules/EntangledModule.sol";
import {BuyerRewardsModule} from "../../contracts/v2/modules/BuyerRewardsModule.sol";
import {NewModulesBase, MockRewardToken} from "./NewModulesBase.t.sol";

abstract contract AllNewModules is NewModulesBase {
    MarketHoursModule mh;
    HotPotatoModule hp;
    PingPongModule pp;
    MomentumModule mo;
    BreathingCapModule bcap;
    SlidingCapsModule sc;
    TitheModule ti;
    BeaconModule bc;
    EntangledModule en;
    BuyerRewardsModule rw;
    MockRewardToken rwd;
    uint32 mhId;
    uint32 hpId;
    uint32 ppId;
    uint32 moId;
    uint32 bcapId;
    uint32 scId;
    uint32 tiId;
    uint32 bcId;
    uint32 enId;
    uint32 rwId;
    address cause = makeAddr("cause");

    uint256 constant MON_OCT5_1000 = 1791208800; // 10:00 New York (EDT)
    uint256 constant MON_OCT5_1600 = 1791230400;

    function setUp() public virtual override {
        super.setUp();
        mh = new MarketHoursModule(address(hook));
        hp = new HotPotatoModule(address(hook));
        pp = new PingPongModule(address(hook));
        mo = new MomentumModule(address(hook));
        bcap = new BreathingCapModule(address(hook));
        sc = new SlidingCapsModule(address(hook));
        ti = new TitheModule(address(hook));
        bc = new BeaconModule(address(hook));
        en = new EntangledModule(address(hook));
        rw = new BuyerRewardsModule(address(hook));
        rwd = new MockRewardToken();
        mhId = modules.addModule(address(mh), "{}");
        hpId = modules.addModule(address(hp), "{}");
        ppId = modules.addModule(address(pp), "{}");
        moId = modules.addModule(address(mo), "{}");
        bcapId = modules.addModule(address(bcap), "{}");
        scId = modules.addModule(address(sc), "{}");
        tiId = modules.addModule(address(ti), "{}");
        bcId = modules.addModule(address(bc), "{}");
        enId = modules.addModule(address(en), "{}");
        rwId = modules.addModule(address(rw), "{}");
    }

    function _mhCfg() internal pure returns (bytes memory) {
        return abi.encode(MarketHoursBase.Config(true, true));
    }

    function _hpCfg() internal pure returns (bytes memory) {
        return abi.encode(HotPotatoModule.Config(10, 1 hours, false));
    }

    function _ppCfg() internal pure returns (bytes memory) {
        return abi.encode(PingPongModule.Config(10, 60));
    }

    function _moCfg() internal pure returns (bytes memory) {
        return abi.encode(MomentumModule.Config(200, 50, 120, 100, 4000));
    }

    function _bcapCfg() internal pure returns (bytes memory) {
        return abi.encode(BreathingCapModule.Config(200, 6000, 50, 7 days)); // (slow breath: the hour-long curve fill stays near base)
    }

    function _scCfg() internal pure returns (bytes memory) {
        SlidingCapsModule.Level[] memory l = new SlidingCapsModule.Level[](1);
        l[0] = SlidingCapsModule.Level(1_000_000, 200, 100);
        return abi.encode(SlidingCapsModule.Config(1000, 1000, l));
    }

    function _tiCfg() internal view returns (bytes memory) {
        return abi.encode(TitheModule.Config(cause, 50));
    }

    function _rwCfg() internal view returns (bytes memory) {
        return abi.encode(BuyerRewardsModule.Config(address(rwd), 1 ether, 1 ether, 0, 0));
    }

    /// Every rule runs on the curve too: fill it on Monday morning (market hours), with buys under the 2%
    /// per-buy caps, a minute apart (the ping-pong timeout frees the turn for each next buy).
    function _graduateMonday(HookTokenV2 t) internal returns (PoolKey memory key) {
        if (vm.getBlockTimestamp() < MON_OCT5_1000) vm.warp(MON_OCT5_1000);
        key = _graduateCapped(t, 19_000_000 ether, 60);
    }
}

/// King of the Hill with seven of the new modules in one launch (the 8-module maximum).
/// forge-config: default.isolate = true
contract NewModulesComboTest is AllNewModules {
    HookTokenV2 t;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        uint32[] memory ids = new uint32[](8);
        bytes[] memory cfgs = new bytes[](8);
        (ids[0], cfgs[0]) = (kothId, _kothCfg(1 ether, 500, 50, 60, false)); // the bar halves every minute
        (ids[1], cfgs[1]) = (mhId, _mhCfg());
        (ids[2], cfgs[2]) = (hpId, _hpCfg());
        (ids[3], cfgs[3]) = (ppId, _ppCfg());
        (ids[4], cfgs[4]) = (moId, _moCfg());
        (ids[5], cfgs[5]) = (tiId, _tiCfg());
        (ids[6], cfgs[6]) = (rwId, _rwCfg());
        (ids[7], cfgs[7]) = (bcId, "");
        t = _launch(ids, cfgs, 100); // Sunday
        key = _graduateMonday(t);
        vm.warp(vm.getBlockTimestamp() + 1 hours); // the curve's King bar decays away, the turn frees up
        rwd.mint(creator, 100 ether);
        vm.startPrank(creator);
        rwd.approve(address(rw), 100 ether);
        rw.fund(address(t), 100 ether);
        vm.stopPrank();
        _mockAvaxUsd(20e18);
    }

    function _king() internal view returns (address k) {
        (k,,,) = koth.currentKing(address(t));
    }

    function _potato() internal view returns (address h) {
        (h,,) = hp.potato(address(t));
    }

    /// After the bell the curve is closed like the pool.
    function test_curveClosedAfterHours() public {
        HookTokenV2 t2 = _launch(_one(mhId), _oneCfg(_mhCfg()), 0);
        vm.warp(MON_OCT5_1600);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1 ether}(address(t2), 0);
    }

    function test_fullGame() public {
        // a curve holder opens the pool's game with a sell (ping pong: the graduating buy was counted, but
        // the turn has been free for an hour)
        address h = _holder(0);
        _routerSell(h, t, 4_000_000 ether);

        // alice: King, potato holder, rewarded; it's sell's turn now
        uint256 c0 = hook.claimable(cause, NATIVE);
        uint256 a = _routerBuy(alice, t, 20 ether);
        assertEq(_king(), alice);
        assertEq(_potato(), alice);
        (uint256 owedA,,,) = rw.owedTo(address(t), alice);
        assertEq(owedA, 1 ether);
        assertEq(hook.claimable(cause, NATIVE) - c0, 0.1 ether);
        assertTrue(_has(_buyError(bob, t, 25 ether), PingPongModule.NotYourTurn.selector));
        // alice holds the potato: her sell is refused (and she stays King)
        assertTrue(_has(_sellError(alice, t, a / 2), HotPotatoModule.PotatoHeld.selector));
        assertEq(_king(), alice);

        // a curve holder sells: the King earns from it, and it's buy's turn
        uint256 k0 = hook.claimable(alice, NATIVE);
        _routerSell(h, t, 4_000_000 ether);
        assertGt(hook.claimable(alice, NATIVE), k0);

        // bob's bigger buy takes the crown and the potato; alice is free to go
        _routerBuy(bob, t, 25 ether);
        assertEq(_king(), bob);
        assertEq(_potato(), bob);
        _routerSell(alice, t, a); // sell's turn: fine, and now it's buy's turn again
        assertTrue(_has(_sellError(h, t, 4_000_000 ether), PingPongModule.NotYourTurn.selector));

        // after the bell nothing trades, but wallets can still send
        vm.warp(MON_OCT5_1600);
        assertTrue(_has(_sellError(h, t, 1 ether), MarketHoursBase.MarketClosed.selector));
        vm.prank(h);
        t.transfer(carol, 1 ether);
        // the beacon only records sustained highs (5 blocks over 15+ minutes); here it is just registered
        (,, bool beaconOn) = bc.beacon(address(t));
        assertTrue(beaconOn);
    }

    function test_gasWithEightModules() public {
        address h = _holder(0);
        _routerSell(h, t, 4_000_000 ether); // buy's turn
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 a = router.buy{value: 20 ether}(address(t), 20 ether, 0, address(0), block.timestamp, "");
        emit log_named_uint("8 modules (KotH+7 new): router buy gas", g - gasleft());
        uint256 amt = 4_000_000 ether;
        vm.startPrank(h);
        t.approve(address(router), amt);
        g = gasleft();
        router.sell(address(t), amt, 0, block.timestamp, "");
        emit log_named_uint("8 modules (KotH+7 new): router sell gas", g - gasleft());
        vm.stopPrank();
        assertGt(a, 0);
    }
}

/// Conflict groups between the new modules (and with the existing ones).
contract NewModulesConflictTest is AllNewModules {
    function launchExt(uint32[] memory ids, bytes[] memory cfgs) external {
        _launch(ids, cfgs, 0);
    }

    function _pair(uint32 a, bytes memory ca, uint32 b, bytes memory cb) internal {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (a, b);
        (cfgs[0], cfgs[1]) = (ca, cb);
        vm.expectRevert(abi.encodeWithSelector(AvaxHookV2.ModuleConflict.selector, b));
        this.launchExt(ids, cfgs);
    }

    function test_conflicts() public {
        _pair(moId, _moCfg(), bcapId, _bcapCfg()); // buyCap
        _pair(moId, _moCfg(), scId, _scCfg()); // buyCap
        _pair(bcapId, _bcapCfg(), scId, _scCfg()); // buyCap
        _pair(hpId, _hpCfg(), enId, abi.encode(EntangledModule.Config(alice, 100_000, 1 days))); // sellLock
    }

    function test_compatiblePairsLaunch() public {
        uint32[] memory ids = new uint32[](3);
        bytes[] memory cfgs = new bytes[](3);
        (ids[0], ids[1], ids[2]) = (mhId, scId, ppId); // tradingWindow + buyCap|sellCap + turnTaking
        (cfgs[0], cfgs[1], cfgs[2]) = (_mhCfg(), _scCfg(), _ppCfg());
        _launch(ids, cfgs, 0);
    }
}

/// Router gas per module: each module alone on a fresh pool vs a pool without modules (first buy and
/// first sell of the pool, same conditions). Isolated (ping pong), so each figure includes the 21k base.
/// forge-config: default.isolate = true
contract NewModulesGasTest is AllNewModules {
    function _measure(string memory label, uint32 id, bytes memory cfg, bool sellToo) internal {
        HookTokenV2 t = id == type(uint32).max ? _launch(new uint32[](0), new bytes[](0), 0) : _launch(_one(id), _oneCfg(cfg), 0);
        _graduateMonday(t);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        uint256 g = gasleft();
        router.buy{value: 20 ether}(address(t), 20 ether, 0, address(0), block.timestamp, "");
        uint256 buyGas = g - gasleft();
        uint256 sellGas;
        if (sellToo) {
            address h = _holder(1);
            uint256 amt = 4_000_000 ether; // 0.4%: counted by ping pong, under every cap
            vm.startPrank(h);
            t.approve(address(router), amt);
            g = gasleft();
            router.sell(address(t), amt, 0, block.timestamp, "");
            sellGas = g - gasleft();
            vm.stopPrank();
        }
        emit log_named_uint(string.concat(label, " buy"), buyGas);
        if (sellToo) emit log_named_uint(string.concat(label, " sell"), sellGas);
    }

    function test_gas_none() public {
        _measure("no modules", type(uint32).max, "", true);
    }

    function test_gas_marketHours() public {
        _measure("market hours", mhId, _mhCfg(), true);
    }

    function test_gas_hotPotato() public {
        _measure("hot potato", hpId, _hpCfg(), true);
    }

    function test_gas_pingPong() public {
        _measure("ping pong (buy only: one swap per tx)", ppId, _ppCfg(), false);
    }

    function test_gas_momentum() public {
        _measure("momentum", moId, _moCfg(), true);
    }

    function test_gas_breathing() public {
        _measure("breathing cap", bcapId, _bcapCfg(), true);
    }

    function test_gas_slidingCaps() public {
        _mockAvaxUsd(20e18);
        _measure("sliding caps", scId, _scCfg(), true);
    }

    function test_gas_tithe() public {
        _measure("tithe", tiId, _tiCfg(), true);
    }

    function test_gas_beacon() public {
        _mockAvaxUsd(20e18);
        _measure("beacon", bcId, "", true);
    }

    function test_gas_buyerRewards() public {
        _measure("buyer rewards (unfunded vault)", rwId, _rwCfg(), true);
    }
}
