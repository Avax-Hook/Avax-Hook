// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookLaunchpadV2} from "../../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../../contracts/v2/AvaxHookV2.sol";
import {AvaxHookRouterV2} from "../../../contracts/v2/AvaxHookRouterV2.sol";
import {HookModuleRegistry} from "../../../contracts/v2/HookModuleRegistry.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AlliancesModule} from "../../../contracts/v2/modules/AlliancesModule.sol";
import {AllowlistModule} from "../../../contracts/v2/modules/AllowlistModule.sol";
import {AntiBundleModule} from "../../../contracts/v2/modules/AntiBundleModule.sol";
import {AntiSnipeModule} from "../../../contracts/v2/modules/AntiSnipeModule.sol";
import {ConvictionCapModule} from "../../../contracts/v2/modules/ConvictionCapModule.sol";
import {CoupledResonatorModule} from "../../../contracts/v2/modules/CoupledResonatorModule.sol";
import {DynamicFeeModule} from "../../../contracts/v2/modules/DynamicFeeModule.sol";
import {GraduatedSellCapModule} from "../../../contracts/v2/modules/GraduatedSellCapModule.sol";
import {HolderDividendsModule} from "../../../contracts/v2/modules/HolderDividendsModule.sol";
import {HolderGatedModule} from "../../../contracts/v2/modules/HolderGatedModule.sol";
import {MomentumModule} from "../../../contracts/v2/modules/MomentumModule.sol";
import {PlagueModule} from "../../../contracts/v2/modules/PlagueModule.sol";

/// Final review 2026-11-10: the fixed modules deployed against the LIVE v3 hook (bytecode of c3b3d6a) on a
/// mainnet fork, registered as the Safe would, launched together, traded on the curve and in the pool.
///   forge test --match-path test/audit/final-1110/SecurityFixesFork.t.sol -vv --isolate
contract SecurityFixesFork is Test {
    AvaxHookV2 constant HOOK = AvaxHookV2(payable(0xfD0753147E21C3F61e38aE27d6634B8C38CB6AcC));
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0xD4C28ec86DAA5227ce6548d42D2DEb890d3C99E1));
    AvaxHookRouterV2 constant ROUTER = AvaxHookRouterV2(payable(0xeeB024bf09aA1c962139bCfE8B964CD9e496B7e6));
    HookModuleRegistry constant REGISTRY = HookModuleRegistry(0xaa3e014D55E5007796D598617061c07D71F2abc7);

    HolderDividendsModule hd;
    ConvictionCapModule cc;
    AntiSnipeModule as_;
    DynamicFeeModule df;
    GraduatedSellCapModule gsc;
    AntiBundleModule ab;
    MomentumModule mom;
    CoupledResonatorModule cr;
    AlliancesModule al;
    AllowlistModule alw;
    HolderGatedModule hg;
    PlagueModule pl;
    mapping(address => uint32) idOf;

    address creator = makeAddr("f-creator");
    address alice = makeAddr("f-alice");
    address bob = makeAddr("f-bob");
    address fresh = makeAddr("f-fresh");

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        address h = address(HOOK);
        require(PAD.hook() == HOOK, "pad/hook");
        hd = new HolderDividendsModule(h);
        cc = new ConvictionCapModule(h);
        as_ = new AntiSnipeModule(h);
        df = new DynamicFeeModule(h);
        gsc = new GraduatedSellCapModule(h);
        ab = new AntiBundleModule(h);
        mom = new MomentumModule(h);
        cr = new CoupledResonatorModule(h);
        al = new AlliancesModule(h);
        alw = new AllowlistModule(h);
        hg = new HolderGatedModule(h);
        pl = new PlagueModule(h);
        address o = REGISTRY.owner();
        address[12] memory all =
            [address(hd), address(cc), address(as_), address(df), address(gsc), address(ab), address(mom), address(cr), address(al), address(alw), address(hg), address(pl)];
        vm.startPrank(o);
        for (uint256 i; i < all.length; ++i) {
            idOf[all[i]] = REGISTRY.addModule(all[i], "{}");
        }
        vm.stopPrank();
    }

    function _launch(address[] memory ms, bytes[] memory cfgs) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Fix";
        a.symbol = "FIX";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3_000});
        a.moduleIds = new uint32[](ms.length);
        for (uint256 i; i < ms.length; ++i) a.moduleIds[i] = idOf[ms[i]];
        a.moduleConfigs = cfgs;
        uint256 fee = PAD.creationFee();
        vm.deal(creator, fee);
        vm.prank(creator);
        t = HookTokenV2(PAD.launch{value: fee}(a));
    }

    function _w(uint256 i) internal pure returns (address) {
        return address(uint160(0xF1A1D000 + i));
    }

    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        PAD.buy{value: amt}(address(t), 0);
    }

    function _routerBuy(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        out = ROUTER.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "");
    }

    function _routerSell(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(who);
        t.approve(address(ROUTER), amt);
        out = ROUTER.sell(address(t), amt, 0, block.timestamp, "");
        vm.stopPrank();
    }

    function _noModuleFailed(Vm.Log[] memory logs) internal pure returns (uint256 failed) {
        bytes32 sig = keccak256("ModuleFailed(bytes32,address,bytes4)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) ++failed;
        }
    }

    /// Six of the fixed modules on one live-hook launch: curve, curve transfers, graduation, pool trades,
    /// dividends paid; no module call fails (ModuleFailed) anywhere.
    function test_e2e_liveHook_sixFixedModules() public {
        address[] memory ms = new address[](6);
        bytes[] memory cfgs = new bytes[](6);
        (ms[0], cfgs[0]) = (address(hd), abi.encode(HolderDividendsModule.Config(300)));
        (ms[1], cfgs[1]) = (address(cc), abi.encode(ConvictionCapModule.Config(1000, 100, 1 hours, 5_000, 0)));
        (ms[2], cfgs[2]) = (address(as_), abi.encode(AntiSnipeModule.Config(20, 50 ether, 500)));
        (ms[3], cfgs[3]) = (address(df), abi.encode(DynamicFeeModule.Config(50_000, 5)));
        (ms[4], cfgs[4]) = (address(gsc), abi.encode(GraduatedSellCapModule.Config(100, 100, 1_000, 50, 0)));
        (ms[5], cfgs[5]) = (address(ab), abi.encode(AntiBundleModule.Config(50, 100, 1)));
        vm.recordLogs();
        HookTokenV2 t = _launch(ms, cfgs);

        // curve: many small buys (under ConvictionCap's 2% start) + v3 curve-phase transfers
        uint256 target = uint256(PAD.getLaunch(address(t)).target);
        uint256 chunk = target / 60 + 1;
        uint256 i;
        for (; i < 400 && !PAD.getLaunch(address(t)).complete; ++i) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 2);
            _curveBuy(_w(i % 40), t, chunk);
            if (i == 5) {
                uint256 b = t.balanceOf(_w(5));
                vm.prank(_w(5));
                t.transfer(fresh, b / 2); // curve transfer to a fresh holder (dividend shares move)
            }
            if (i == 7) {
                uint256 s7 = t.balanceOf(_w(7)) / 20;
                vm.prank(_w(7));
                PAD.sell(address(t), s7, 0);
            }
        }
        assertTrue(PAD.getLaunch(address(t)).graduated, "graduated");
        emit log_named_uint("curve buys to graduate", i);

        // pool phase within AntiSnipe's guard: buy, sell, buy in the same block
        _routerBuy(alice, t, 1 ether);
        _routerSell(_w(1), t, t.balanceOf(_w(1)) / 20);
        _routerBuy(bob, t, 1 ether);
        vm.roll(block.number + 30);
        vm.warp(block.timestamp + 60);
        for (uint256 k; k < 6; ++k) {
            _routerBuy(_w(k), t, 2 ether);
            vm.roll(block.number + 1);
            _routerSell(_w(k + 10), t, t.balanceOf(_w(k + 10)) / 20);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 3);
        }
        uint256 half = t.balanceOf(alice) / 2;
        vm.prank(alice);
        t.transfer(fresh, half);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_noModuleFailed(logs), 0, "a module call failed on the live hook");

        // dividends: owed to holders and claimable
        hd.reconcile();
        uint256 owed = hd.pending(address(t), _w(3));
        assertGt(owed, 0, "holder earned dividends");
        uint256 before = _w(3).balance;
        vm.prank(_w(3));
        hd.claim(address(t));
        assertEq(_w(3).balance - before, owed, "claimed");
        assertGt(hd.pending(address(t), fresh), 0, "transferee earns too");
    }

    /// HolderDividends.onTransfer now folds the pending credit first: worst case (a fresh receiver, the pending
    /// credit folded in the same call) must still fit the hook's 200k module budget with room to spare.
    function test_holderDividends_onTransferGas() public {
        address[] memory ms = new address[](1);
        bytes[] memory cfgs = new bytes[](1);
        (ms[0], cfgs[0]) = (address(hd), abi.encode(HolderDividendsModule.Config(1000)));
        HookTokenV2 t = _launch(ms, cfgs);
        _curveBuy(alice, t, 5 ether);
        _curveBuy(bob, t, 5 ether); // leaves a pending (unverified) credit
        PoolId id = HOOK.poolOfToken(address(t));
        // measure the module call alone, as the hook makes it (cold where the real call is cold under --isolate)
        address to = makeAddr("never-seen");
        vm.prank(alice);
        t.transfer(to, 1 ether); // the real path (would revert if the module ran out of its 200k)
        // and a direct measurement of the worst case on a second fresh receiver after another trade
        _curveBuy(alice, t, 1 ether);
        address to2 = makeAddr("never-seen-2");
        vm.prank(address(HOOK));
        uint256 g = gasleft();
        hd.onTransfer(id, address(t), alice, alice, to2, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("HolderDividends.onTransfer gas (fold + fresh receiver, warm-ish)", used);
        assertLt(used, 200_000, "within MODULE_GAS");
    }

    /// AntiSnipe now counts net buying in the block: shows how much gross buying one wallet gets through in
    /// one guarded block by alternating sells of tokens it already holds (curve bag) with buys.
    function test_antiSnipe_netting_grossThroughput() public {
        address[] memory ms = new address[](1);
        bytes[] memory cfgs = new bytes[](1);
        (ms[0], cfgs[0]) = (address(as_), abi.encode(AntiSnipeModule.Config(100, 2 ether, 0)));
        HookTokenV2 t = _launch(ms, cfgs);
        uint256 chunk = uint256(PAD.getLaunch(address(t)).target) / 20 + 1;
        for (uint256 i; i < 60 && !PAD.getLaunch(address(t)).complete; ++i) {
            vm.roll(block.number + 1);
            _curveBuy(_w(i % 10), t, chunk);
        }
        assertTrue(PAD.getLaunch(address(t)).graduated, "graduated");
        address sniper = _w(0);
        vm.roll(block.number + 1);
        uint256 bought;
        // cap 2 AVAX per block: buy 2, sell bag for X quote, buy X more, ...
        bought += _routerBuy(sniper, t, 2 ether);
        uint256 got = _routerSell(sniper, t, t.balanceOf(sniper) / 2);
        emit log_named_uint("quote freed by the sniper's own sell", got);
        bought += _routerBuy(sniper, t, 2 ether); // the sell freed the whole 2-AVAX count (floored at 0)
        emit log_named_uint("tokens bought by one wallet in one guarded block", bought);
        // a third gross buy above the remaining net cap still reverts
        vm.deal(sniper, 10 ether);
        vm.prank(sniper);
        vm.expectRevert();
        ROUTER.buy{value: 3 ether}(address(t), 3 ether, 0, address(0), block.timestamp, "");
    }
}
