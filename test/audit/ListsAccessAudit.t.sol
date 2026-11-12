// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {PlagueModule} from "../../contracts/v2/modules/PlagueModule.sol";
import {AlliancesModule} from "../../contracts/v2/modules/AlliancesModule.sol";
import {HolderGatedModule} from "../../contracts/v2/modules/HolderGatedModule.sol";
import {AllowlistModule} from "../../contracts/v2/modules/AllowlistModule.sol";
import {BlocklistModule} from "../../contracts/v2/modules/BlocklistModule.sol";
import {AutoLpModule} from "../../contracts/v2/modules/AutoLpModule.sol";
import {DirectSwapper} from "../v2/V2Mocks.sol";
import {MockRewardToken} from "../v2/NewModulesBase.t.sol";
import {ListsAccessBase} from "../v2/ListsAccessBase.t.sol";

/// balanceOf burns ~all of its gas budget and returns 0.
contract GasBurnerToken {
    function balanceOf(address) external view returns (uint256) {
        uint256 x;
        while (gasleft() > 500) x++;
        return 0;
    }
}

/// Owner-switchable balanceOf (stands in for an upgradeable / creator-controlled ERC-20).
contract SwitchToken {
    bool public evil;
    function flip() external { evil = true; }
    function balanceOf(address) external view returns (uint256) {
        return evil ? type(uint256).max : 0;
    }
}

contract Create2Deployer {
    function deploy(bytes32 salt, bytes memory code) external returns (address a) {
        assembly { a := create2(0, add(code, 32), mload(code), salt) }
        require(a != address(0));
    }
    function addr(bytes32 salt, bytes32 codeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
    }
}

/// Audit PoCs for package 1, turned into regression tests for the fixes (M-1..M-3, L-1..L-3).
contract ListsAccessAudit is ListsAccessBase {
    PlagueModule pl;
    uint32 plId;
    AlliancesModule am;
    uint32 amId;
    HolderGatedModule hg;
    uint32 hgId;
    BlocklistModule bl;
    uint32 blId;

    function setUp() public override {
        super.setUp();
        pl = new PlagueModule(address(hook));
        plId = modules.addModule(address(pl), '{"name":"Plague"}');
        am = new AlliancesModule(address(hook));
        amId = modules.addModule(address(am), '{"name":"Alliances"}');
        hg = new HolderGatedModule(address(hook));
        hgId = modules.addModule(address(hg), '{"name":"HolderGated"}');
        bl = new BlocklistModule(address(hook));
        blId = modules.addModule(address(bl), '{"name":"Blocklist"}');
    }

    function _addLp(PoolKey memory key, address who) internal returns (PoolModifyLiquidityTest lp) {
        lp = new PoolModifyLiquidityTest(PM);
        HookTokenV2 t = HookTokenV2(Currency.unwrap(key.currency1));
        vm.deal(who, who.balance + 20 ether);
        vm.startPrank(who);
        t.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 10 ether}(
            key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e18, 0), ""
        );
        vm.stopPrank();
    }

    function _removeLp(PoolKey memory key, PoolModifyLiquidityTest lp, address who, bool expectRevert) internal {
        vm.prank(who);
        if (expectRevert) vm.expectRevert();
        lp.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -1e18, 0), "");
    }

    /// M-2 fixed: an uninfected LP can always remove its liquidity (a PoolManager outflow that is not a swap
    ///    output is never checked); a pool buy to the same wallet is still refused.
    /// forge-config: default.isolate = true
    function test_plague_uninfectedLpTrapped() public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(abi.encode(PlagueModule.Config(1_000 ether, 0))), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        address lpUser = makeAddr("lpUser");
        _send(t, _holder(0), lpUser, 999 ether); // below minInfect: not infected
        assertFalse(pl.infected(address(t), lpUser));
        PoolModifyLiquidityTest lp = _addLp(key, lpUser);
        uint256 b0 = t.balanceOf(lpUser);
        _removeLp(key, lp, lpUser, false);
        assertGt(t.balanceOf(lpUser), b0, "LP got its tokens back");
        assertFalse(pl.infected(address(t), lpUser), "withdrawals never infect");
        vm.deal(lpUser, 1 ether);
        _buyReverts(lpUser, t, 1 ether);
    }

    /// L-3 (accepted, now documented in NatSpec + JSON): CREATE2 pre-infection. An infected EOA sends minInfect
    ///    to a counterfactual address (no code -> counts as EOA -> infected), then a buy-for-anyone contract is
    ///    deployed there: a public carrier. This test pins the documented behaviour.
    function test_plague_create2CarrierBypass() public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(abi.encode(PlagueModule.Config(1_000 ether, 0))), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        Create2Deployer d = new Create2Deployer();
        bytes memory code = abi.encodePacked(type(DirectSwapper).creationCode, abi.encode(PM));
        address future = d.addr(bytes32(0), keccak256(code));
        _send(t, _holder(0), future, 1_000 ether);
        assertTrue(pl.infected(address(t), future), "counterfactual address infected");
        DirectSwapper carrier = DirectSwapper(payable(d.deploy(bytes32(0), code)));
        assertEq(address(carrier), future);
        vm.deal(address(carrier), 10 ether);
        // Since the 2026-11-12 claims-bypass guard the carrier can't buy on the PoolManager directly while the
        // plague is on (RouterOnly). A carrier that buys through the AvaxHook router (it is then the infected
        // trader and receiver) remains the documented L-3 behaviour.
        try carrier.swap(key, true, -int256(1 ether)) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        assertEq(t.balanceOf(address(carrier)), 1_000 ether);
    }

    /// M-2 fixed: an LP that no longer holds the gate token can still remove its liquidity; M-3: a gate token
    ///    that is neither a v2 token nor an allowed quote (e.g. creator-switchable) is refused at launch.
    /// forge-config: default.isolate = true
    function test_holderGated_lpWithoutGateTrapped() public {
        _launchReverts(hgId, abi.encode(HolderGatedModule.Config(address(new SwitchToken()), 1 ether, 0)));
        MockRewardToken gate = new MockRewardToken();
        _allowQuote(address(gate));
        HookTokenV2 t = _launch(_one(hgId), _oneCfg(abi.encode(HolderGatedModule.Config(address(gate), 1 ether, 0))), 0);
        // graduate: holders need the gate
        for (uint256 i; i < 120; ++i) gate.mint(_holder(i), 1 ether);
        PoolKey memory key = _graduateN(t, 40, 0);
        address lpUser = makeAddr("lpUser");
        gate.mint(lpUser, 1 ether);
        _send(t, _holder(0), lpUser, 1_000 ether);
        PoolModifyLiquidityTest lp = _addLp(key, lpUser);
        // LP sells / moves its gate tokens (e.g. gate token is HOOK and it trades it)
        vm.prank(lpUser);
        gate.transfer(alice, 1 ether);
        _removeLp(key, lp, lpUser, false);
        vm.deal(lpUser, 1 ether);
        _buyReverts(lpUser, t, 1 ether); // buys still gated
    }

    /// M-3 fixed: a launch-time rival (or ally) that is an arbitrary, creator-controlled ERC-20 is refused at
    ///    launch, and so is a post-launch rival. M-2: with an honest rival, an LP that picks up the rival token
    ///    can still remove its liquidity.
    /// forge-config: default.isolate = true
    function test_alliances_switchRivalBricksReceives() public {
        SwitchToken sw = new SwitchToken();
        address[] memory rivals = new address[](1);
        rivals[0] = address(sw);
        _launchReverts(amId, abi.encode(AlliancesModule.Config(0, 1 ether, 1 ether, new address[](0), rivals)));
        _launchReverts(amId, abi.encode(AlliancesModule.Config(0, 1 ether, 1 ether, rivals, new address[](0))));

        MockRewardToken honest = new MockRewardToken();
        _allowQuote(address(honest));
        rivals[0] = address(honest);
        HookTokenV2 t = _launch(
            _one(amId), _oneCfg(abi.encode(AlliancesModule.Config(0, 1 ether, 1 ether, new address[](0), rivals))), 0
        );
        vm.expectRevert(AlliancesModule.BadTreaty.selector);
        vm.prank(creator);
        am.proposeTreaty(address(t), address(sw), 2);
        PoolKey memory key = _graduateN(t, 40, 0);
        address lpUser = makeAddr("lpUser");
        _send(t, _holder(0), lpUser, 1_000 ether);
        PoolModifyLiquidityTest lp = _addLp(key, lpUser);
        honest.mint(lpUser, 1 ether);
        _removeLp(key, lp, lpUser, false);
        vm.deal(lpUser, 1 ether);
        _buyReverts(lpUser, t, 1 ether); // buys still refused for rival holders
        _routerSell(_holder(1), t, t.balanceOf(_holder(1)));
    }

    /// L-2 fixed: dropTreaty no longer strips the OTHER token's own launch-time ally entry; only entries an
    ///    accepted alliance added are removed on the other side.
    function test_alliances_dropStripsOthersLaunchAlly() public {
        address otherCreator = makeAddr("otherCreator");
        // A launches first (no treaties)
        HookTokenV2 a = _launch(_one(amId), _oneCfg(abi.encode(AlliancesModule.Config(500, 1 ether, 1 ether, new address[](0), new address[](0)))), 0);
        // B launches naming A as a one-way launch ally
        address[] memory allies = new address[](1);
        allies[0] = address(a);
        HookTokenV2 b = _launchAs(otherCreator, abi.encode(AlliancesModule.Config(500, 1 ether, 1 ether, allies, new address[](0))));
        // A's creator gets B into A's allies the cheap way? Needs B's acceptance... instead a third token C
        // launched by A's creator listing B at launch is enough: C's creator drops B and removes C from B.
        // Show the simpler mutual case: B lists A at launch; A proposes, B accepts (no-op on B's side since A
        // is already there); later A drops -> B's launch-time entry for A is gone too.
        vm.prank(creator);
        am.proposeTreaty(address(a), address(b), 1);
        vm.prank(otherCreator);
        am.acceptAlliance(address(b), address(a));
        vm.prank(creator);
        am.dropTreaty(address(a), address(b));
        (address[] memory bAllies,,,,) = am.treaties(address(b));
        assertEq(bAllies.length, 1, "B's launch-time ally entry stays");
        assertEq(bAllies[0], address(a));
        (address[] memory aAllies,,,,) = am.treaties(address(a));
        assertEq(aAllies.length, 0, "A's own entry is gone");
        // an alliance-added entry IS removed on both sides
        HookTokenV2 c = _launchAs(otherCreator, abi.encode(AlliancesModule.Config(500, 1 ether, 1 ether, new address[](0), new address[](0))));
        vm.prank(creator);
        am.proposeTreaty(address(a), address(c), 1);
        vm.prank(otherCreator);
        am.acceptAlliance(address(c), address(a));
        assertTrue(am.viaAlliance(address(c), address(a)));
        vm.prank(otherCreator);
        am.dropTreaty(address(c), address(a));
        (aAllies,,,,) = am.treaties(address(a));
        (address[] memory cAllies,,,,) = am.treaties(address(c));
        assertEq(aAllies.length + cAllies.length, 0, "alliance broken both ways");
    }

    function _launchAs(address who, bytes memory cfg) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory x;
        x.name = "B";
        x.symbol = "B";
        x.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        x.moduleIds = _one(amId);
        x.moduleConfigs = _oneCfg(cfg);
        uint256 fee = pad.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        t = HookTokenV2(pad.launch{value: fee}(x));
    }

    /// L-1 fixed: 8 reads x 20k stay under MODULE_GAS. Treaty tokens whose balanceOf burns its whole budget
    ///    (etched over allowed tokens after launch) still let a real visa holder (4th ally) through.
    function test_alliances_gasBudgetExceeded() public {
        address[] memory allies = new address[](4);
        address[] memory rivals = new address[](4);
        for (uint256 i; i < 4; ++i) {
            allies[i] = address(new MockRewardToken());
            rivals[i] = address(new MockRewardToken());
            _allowQuote(allies[i]);
            _allowQuote(rivals[i]);
        }
        HookTokenV2 t = _launch(_one(amId), _oneCfg(abi.encode(AlliancesModule.Config(500, 1 ether, 1 ether, allies, rivals))), 0);
        bytes memory burner = address(new GasBurnerToken()).code;
        for (uint256 i; i < 4; ++i) vm.etch(rivals[i], burner);
        for (uint256 i; i < 3; ++i) vm.etch(allies[i], burner);
        MockRewardToken(allies[3]).mint(bob, 1 ether);
        (, bool visa) = am.standing(address(t), bob);
        assertTrue(visa, "view says visa");
        uint256 big = _target(t) / 2;
        _curveBuy(bob, t, big); // the transfer passes within the module budget
        assertGt(t.balanceOf(bob), SUPPLY * 500 / 10_000);
    }

    /// Blocklist launch gas with 200 distinct addresses.
    function test_blocklist_launchGas200() public {
        address[] memory list = new address[](200);
        for (uint256 i; i < 200; ++i) list[i] = address(uint160(0x10000 + i));
        uint256 g = gasleft();
        _launch(_one(blId), _oneCfg(abi.encode(BlocklistModule.Config(list))), 0);
        console2.log("launch gas with 200-address blocklist", g - gasleft());
    }

    /// M-1 fixed: Plague + Auto-LP: compound's token claim and fee take (PoolManager -> Auto-LP module) pass:
    ///    modules of the same pool are exempt receivers and non-swap PoolManager outflows aren't checked.
    function test_plague_breaksAutoLpCompound() public {
        AutoLpModule autoLp = new AutoLpModule(address(hook));
        uint32 alId = modules.addModule(address(autoLp), '{"name":"Auto-LP"}');
        uint32[] memory ids = new uint32[](2);
        ids[0] = plId;
        ids[1] = alId;
        bytes[] memory cfgs = new bytes[](2);
        cfgs[0] = abi.encode(PlagueModule.Config(1_000 ether, 0));
        cfgs[1] = abi.encode(AutoLpModule.Config(200, 1 ether));
        HookTokenV2 t = _launch(ids, cfgs, 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        assertGt(autoLp.vaultOf(_id(key)).saved, 1 ether);
        vm.roll(vm.getBlockNumber() + 61);
        _routerBuy(_holder(0), t, 0.01 ether); // checkpoint (infected buyer)
        vm.roll(vm.getBlockNumber() + 30);
        autoLp.compound(key);
    }

    /// M-1 for the other receiver rules: Auto-LP compounds next to HolderGated and Allowlist too.
    function test_receiverRules_autoLpCompounds() public {
        AutoLpModule autoLp = new AutoLpModule(address(hook));
        uint32 alpId = modules.addModule(address(autoLp), '{"name":"Auto-LP"}');
        AllowlistModule alw = new AllowlistModule(address(hook));
        uint32 alwId = modules.addModule(address(alw), '{"name":"Allowlist"}');
        MockRewardToken gate = new MockRewardToken();
        _allowQuote(address(gate));
        address[] memory list = new address[](121);
        for (uint256 i; i < 120; ++i) {
            gate.mint(_holder(i), 1 ether);
            list[i] = _holder(i);
        }
        list[120] = alice;
        bytes[2] memory rules = [
            abi.encode(HolderGatedModule.Config(address(gate), 1 ether, 0)),
            abi.encode(AllowlistModule.Config(list, bytes32(0), 0))
        ];
        uint32[2] memory ruleIds = [hgId, alwId];
        for (uint256 k; k < 2; ++k) {
            uint32[] memory ids = new uint32[](2);
            (ids[0], ids[1]) = (ruleIds[k], alpId);
            bytes[] memory cfgs = new bytes[](2);
            (cfgs[0], cfgs[1]) = (rules[k], abi.encode(AutoLpModule.Config(200, 1 ether)));
            HookTokenV2 t = _launch(ids, cfgs, 0);
            PoolKey memory key = _graduateN(t, 40, 0);
            vm.roll(vm.getBlockNumber() + 61);
            _routerBuy(_holder(0), t, 0.01 ether);
            vm.roll(vm.getBlockNumber() + 30);
            autoLp.compound(key);
        }
    }
}
