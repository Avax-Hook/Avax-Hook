// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookTokenV3} from "../../contracts/v3/HookTokenV3.sol";
import {BlocklistModule} from "../../contracts/v2/modules/BlocklistModule.sol";
import {ConvictionCapModule} from "../../contracts/v2/modules/ConvictionCapModule.sol";
import {DexOnlyModule} from "../../contracts/v2/modules/DexOnlyModule.sol";
import {GraduatedSellCapModule} from "../../contracts/v2/modules/GraduatedSellCapModule.sol";
import {GrudgeModule} from "../../contracts/v2/modules/GrudgeModule.sol";
import {HolderVestingModule} from "../../contracts/v2/modules/HolderVestingModule.sol";
import {HotPotatoModule} from "../../contracts/v2/modules/HotPotatoModule.sol";
import {JackpotModule} from "../../contracts/v2/modules/JackpotModule.sol";
import {KingOfTheHillModule} from "../../contracts/v2/modules/KingOfTheHillModule.sol";
import {MaxPerWalletModule} from "../../contracts/v2/modules/MaxPerWalletModule.sol";
import {V3Base} from "./V3Base.t.sol";

/**
 * The transfer rules against each other, on the one thing v3 adds: a wallet-to-wallet move while the
 * token is still on its curve. On v2 that move always reverted in the token, so no combination of
 * modules had ever seen one — now every ON_TRANSFER module runs on it, in launch order, and a module
 * that reverts stops the transfer.
 *
 * What this asks of any set of them (up to 8, as a launch may pick):
 *   - the launch either refuses the set outright (a conflict) or trades;
 *   - a refused transfer fails with a module's own error, never a Panic (overflow, division, assert)
 *     and never with empty revert data, which is what one module breaking another looks like;
 *   - a refused transfer leaves the curve working: someone else can still buy, and the holder can
 *     still sell unless a module says otherwise, again without a Panic.
 *
 *   forge test --match-path test/v3/CurveTransferCombos.t.sol
 */
contract CurveTransferCombos is V3Base {
    /// Panic(uint256) — a module breaking, not a rule refusing.
    bytes4 constant PANIC = 0x4e487b71;

    uint32[] ids;
    bytes[] cfgs;
    address blocked = makeAddr("blocked");

    function _registerModules() internal override {
        address h = address(hook);
        // One per conflict group, plus the group-less ones: a set the registry accepts in any combination.
        _add(address(new MaxPerWalletModule(h)), abi.encode(MaxPerWalletModule.Config(500, 0, false)));
        _add(address(new ConvictionCapModule(h)), abi.encode(ConvictionCapModule.Config(100, 100, 1 hours, 5_000, 0)));
        _add(
            address(new GraduatedSellCapModule(h)),
            abi.encode(GraduatedSellCapModule.Config(100, 100, 1_000, 50, 0))
        );
        address[] memory list = new address[](1);
        list[0] = blocked;
        _add(address(new BlocklistModule(h)), abi.encode(BlocklistModule.Config(list)));
        _add(address(new HotPotatoModule(h)), abi.encode(HotPotatoModule.Config(100, 1 hours, false)));
        _add(address(new KingOfTheHillModule(h)), abi.encode(KingOfTheHillModule.Config(0.1 ether, 500, 50, 0, false)));
        _add(address(new GrudgeModule(h)), abi.encode(GrudgeModule.Config(5_000, 1 hours, 1 days, 2, 0, 1_000)));
        _add(address(new JackpotModule(h)), abi.encode(JackpotModule.Config(100, 1 hours, 0.1 ether, 10)));
        _add(address(new DexOnlyModule(h)), abi.encode(DexOnlyModule.Config(0)));
        _add(address(new HolderVestingModule(h)), abi.encode(HolderVestingModule.Config(0, 10, 1 days, 2_500, 1 days)));
    }

    function _add(address impl, bytes memory config) internal {
        ids.push(modules.addModule(impl, "{}"));
        cfgs.push(config);
    }

    /// Every module at once: the launch takes 8 of them (MAX_MODULES), and a curve transfer runs them all.
    function test_eightTransferRules_onTheCurve() public {
        (uint32[] memory pick, bytes[] memory picked) = _subset((1 << 8) - 1); // the first eight
        assertEq(pick.length, 8, "eight modules");
        HookTokenV3 t = _launch(pick, picked);
        uint256 got = _buy(alice, t, 1 ether);
        assertGt(got, 0, "bought with eight rules on");
        _probeTransfer(t, got / 4);
        _probeCurveStillWorks(t);
    }

    /// Any set of them, by seed: at most 8, and a conflicting set is skipped (the hook refuses it).
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_anyTransferRuleSet(uint16 seed) public {
        (uint32[] memory pick, bytes[] memory picked) = _subset(seed);
        if (pick.length == 0) return;
        HookTokenV3 t;
        try this.launchFor(pick, picked) returns (address token) {
            t = HookTokenV3(token);
        } catch (bytes memory err) {
            // A refused launch is the registry's or a module's own error, never a Panic.
            assertGt(err.length, 3, "empty revert on launch");
            assertTrue(bytes4(err) != PANIC, "Panic on launch");
            return;
        }
        uint256 got = _buy(alice, t, 1 ether);
        if (got == 0) return; // a buy cap refused it: nothing to send on
        _probeTransfer(t, got / 4);
        _probeCurveStillWorks(t);
    }

    /// external so the fuzz case can `try` it
    function launchFor(uint32[] memory pick, bytes[] memory picked) external returns (address) {
        require(msg.sender == address(this), "self");
        return address(_launch(pick, picked));
    }

    // ---------------------------------------------------------------- helpers

    /// The modules whose bit is set in `mask`, capped at MAX_MODULES.
    function _subset(uint16 mask) internal view returns (uint32[] memory pick, bytes[] memory picked) {
        uint256 n;
        uint256 len = ids.length;
        uint32[] memory bufIds = new uint32[](8);
        bytes[] memory bufCfg = new bytes[](8);
        for (uint256 i; i < len && n < 8; ++i) {
            if (mask & (1 << i) == 0) continue;
            bufIds[n] = ids[i];
            bufCfg[n] = cfgs[i];
            ++n;
        }
        pick = new uint32[](n);
        picked = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            pick[i] = bufIds[i];
            picked[i] = bufCfg[i];
        }
    }

    /// A curve-phase send: it may be refused, but only by a module saying so.
    function _probeTransfer(HookTokenV3 t, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(t).call(abi.encodeCall(IERC20.transfer, (bob, amount)));
        if (ok) {
            assertEq(t.balanceOf(bob), amount, "the send moved exactly what was sent");
            return;
        }
        assertGt(ret.length, 3, "a refused curve transfer returned empty revert data");
        assertTrue(bytes4(ret) != PANIC, "a curve transfer hit a Panic inside a module");
    }

    /// The curve is not bricked by whatever just happened: another wallet can buy, and a sell is either
    /// allowed or refused by a module (never a Panic).
    function _probeCurveStillWorks(HookTokenV3 t) internal {
        address fresh = makeAddr("fresh-buyer");
        vm.deal(fresh, 10 ether);
        vm.prank(fresh);
        (bool bought,) = address(pad).call{value: 0.5 ether}(
            abi.encodeCall(HookLaunchpadV2.buy, (address(t), uint256(0)))
        );
        // A cap may refuse this buyer too; what matters is that the curve itself is still answering.
        if (!bought) {
            assertFalse(pad.getLaunch(address(t)).complete, "the curve closed, which is not a refusal");
        }
        uint256 bal = t.balanceOf(alice);
        if (bal == 0) return;
        vm.prank(alice);
        (bool sold, bytes memory ret) = address(pad).call(
            abi.encodeCall(HookLaunchpadV2.sell, (address(t), bal / 2, uint256(0)))
        );
        if (!sold) {
            assertGt(ret.length, 3, "a refused sell returned empty revert data");
            assertTrue(bytes4(ret) != PANIC, "a sell hit a Panic inside a module");
        }
    }
}
