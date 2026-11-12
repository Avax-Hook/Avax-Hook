// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HookModuleBase} from "../../contracts/v2/modules/HookModuleBase.sol";
import {LedgerModuleBase} from "../../contracts/v2/modules/LedgerModuleBase.sol";
import {HookModuleRegistry} from "../../contracts/v2/HookModuleRegistry.sol";
import {V1PortBase} from "./V1PortBase.t.sol";
import {CurveProbe} from "./CurveModules.t.sol";

/// A sell-path module without BLOCKS_SELLS that returns hostile data (M-1 PoC). Buys: no credits.
contract BadReturnModule is HookModuleBase {
    uint8 public mode; // 1: one 32-byte word, 2: credit to address(0), 3: 1,000 one-wei credits, 4: two max-uint credits

    constructor(address _hook) HookModuleBase(_hook) {}

    function setMode(uint8 m) external {
        mode = m;
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata) public pure override {}

    function onRegister(PoolId, address, address, address, bytes calldata) external override onlyHook {}

    function onBeforeSwap(SwapContext calldata ctx) external view override returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) _hostile(true);
        return (0, new Credit[](0));
    }

    function onAfterSwap(SwapContext calldata ctx) external view override returns (Credit[] memory) {
        if (!ctx.isBuy) _hostile(false);
        return new Credit[](0);
    }

    function _hostile(bool before) internal view {
        uint8 m = mode;
        if (m == 1) {
            assembly {
                mstore(0, 0x20)
                return(0, 32)
            }
        }
        (uint256 n, address to, uint256 amt) = (2, address(this), type(uint256).max);
        if (m == 2) (n, to, amt) = (1, address(0), 1 ether);
        if (m == 3) (n, to, amt) = (1_000, address(this), 1);
        assembly {
            let p := mload(0x40)
            let q := p
            switch before
            case 1 {
                mstore(q, 0)
                mstore(add(q, 32), 0x40)
                q := add(q, 64)
            }
            default {
                mstore(q, 0x20)
                q := add(q, 32)
            }
            mstore(q, n)
            q := add(q, 32)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(q, to)
                mstore(add(q, 32), amt)
                q := add(q, 64)
            }
            return(p, sub(q, p))
        }
    }
}

/// Regressions for the v2 audit fixes (core rules M, M-1, M-2, I-3; modules L-1, L-2, L-3).
contract AuditFixesV2Test is V1PortBase {
    function _ids4(uint32 a, uint32 b, uint32 c, uint32 d) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (a, b, c, d);
    }

    function _cfgs4(bytes memory a, bytes memory b, bytes memory c, bytes memory d) internal pure returns (bytes[] memory r) {
        r = new bytes[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    // ---------------------------------------------------------------- rules M: cut cap scales, never bricks

    /// Auditor's combo: Referral 9% + NthBuyPot 10% + LastBuyerPot 6% (25% on the curve) + LpRewards 10% (pool
    /// only) = 35% of every pool buy. It graduates, and pool buys work with every credit scaled by 25/35.
    function test_overCapComboGraduatesAndPoolBuysScale() public {
        (HookTokenV2 t, PoolKey memory key) = _many(
            _ids4(referralId, nthPotId, timerPotId, lpId),
            _cfgs4(_referralCfg(900, 200), _nthCfg(1_000, 1_000, 0.1 ether), _timerCfg(600, 7 days, 0.1 ether), _lpCfg(1_000)),
            100
        );
        PoolId id = _id(key);
        assertTrue(hook.isOpen(id));
        uint256 cr0 = hook.claimable(creator, NATIVE);
        uint256 n0 = hook.claimable(address(nthPot), NATIVE);
        uint256 l0 = hook.claimable(address(timerPot), NATIVE);
        uint256 np0 = nthPot.potOf(id).pot;
        uint256 lp0 = timerPot.potOf(id).pot;
        vm.recordLogs();
        _routerBuy(bob, t, 1 ether);
        // module credits on the input side add up to exactly the 25% cap (LP donation included)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ModuleCredit(bytes32,address,address,address,uint256)");
        uint256 sum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == sig) {
                (, uint256 amt) = abi.decode(logs[i].data, (Currency, uint256));
                if (Currency.unwrap(abi.decode(logs[i].data, (Currency))) == address(0)) sum += amt;
            }
        }
        assertApproxEqAbs(sum, 0.25 ether, 4);
        assertApproxEqAbs(hook.claimable(address(nthPot), NATIVE) - n0, uint256(0.1 ether) * 25 / 35, 1);
        assertApproxEqAbs(hook.claimable(address(timerPot), NATIVE) - l0, uint256(0.06 ether) * 25 / 35, 1);
        assertApproxEqAbs(hook.claimable(creator, NATIVE) - cr0, 0.01 ether + uint256(0.09 ether) * 25 / 35, 1);
        // the pots' books follow what the hook really booked
        nthPot.reconcile();
        timerPot.reconcile();
        assertEq(nthPot.potOf(id).pot - np0, hook.claimable(address(nthPot), NATIVE) - n0);
        assertEq(timerPot.potOf(id).pot - lp0, hook.claimable(address(timerPot), NATIVE) - l0);
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
        assertEq(timerPot.accounted(address(0)), hook.claimable(address(timerPot), NATIVE));
        // trading keeps working both ways
        vm.roll(vm.getBlockNumber() + 1);
        uint256 got = _routerBuy(alice, t, 2 ether);
        _routerSell(alice, t, got);
    }

    // ---------------------------------------------------------------- M-1: hostile isolated module

    function test_hostileSellModuleCantBrickSells() public {
        BadReturnModule bad = new BadReturnModule(address(hook));
        uint32 badId = modules.addModule(address(bad), '{"name":"bad"}');
        HookTokenV2 t = _launch(_ids1(badId), _cfgs1(""), 100);
        vm.roll(vm.getBlockNumber() + CURVE_WINDOWS);
        Currency tc = Currency.wrap(address(t));

        // bonding curve
        vm.prank(alice);
        pad.buy{value: 5 ether}(address(t), 0);
        uint256 bal = t.balanceOf(alice);
        for (uint8 m = 1; m <= 4; ++m) {
            bad.setMode(m);
            vm.prank(alice);
            pad.sell(address(t), bal / 10, 0);
        }
        // 1,000 one-wei credits: only MAX_CREDITS (8) per callback are read
        assertApproxEqAbs(hook.claimable(address(bad), tc), 8 + bal / 10 / 4, 1); // + mode 4: the cap, rounded down
        assertGt(hook.claimable(address(bad), NATIVE), 8);

        // pool
        _graduate(t);
        bad.setMode(0);
        uint256 got = _routerBuy(bob, t, 5 ether);
        uint256 k0 = hook.claimable(address(bad), tc);
        uint256 n0 = hook.claimable(address(bad), NATIVE);
        for (uint8 m = 1; m <= 3; ++m) {
            bad.setMode(m);
            assertGt(_routerSell(bob, t, got / 10), 0);
        }
        assertEq(hook.claimable(address(bad), tc) - k0, 8);
        assertEq(hook.claimable(address(bad), NATIVE) - n0, 8);
        // two max-uint credits: clamped to the cap and scaled, never an overflow
        bad.setMode(4);
        uint256 out = _routerSell(bob, t, got / 10);
        assertGt(out, 0);
        assertApproxEqAbs(hook.claimable(address(bad), tc) - k0 - 8, got / 10 / 4, 1);
    }

    // ---------------------------------------------------------------- M-2: graduation excess to the creator

    /// Auditor's scenario: a module with a 30% curve extra fee piles quote into `bonus`; the part the pool
    /// position can't take goes to the creator, not the protocol.
    function test_bonusExcessGoesToCreator() public {
        CurveProbe p = new CurveProbe(address(hook), ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP);
        uint32 pid = modules.addModule(address(p), '{"name":"fee"}');
        p.set(address(p), 0, 0, 300_000);
        HookTokenV2 t = _launch(_ids1(pid), _cfgs1(""), 100);
        vm.roll(vm.getBlockNumber() + CURVE_WINDOWS);
        // defer graduation so the state right before it can be read
        vm.mockCallRevert(address(PM), abi.encodeWithSelector(IPoolManager.initialize.selector), "deferred");
        uint256 chunk = uint256(pad.getLaunch(address(t)).target) / 8;
        for (uint256 i; i < 20 && !pad.getLaunch(address(t)).complete; ++i) {
            address w = address(uint160(0xB0B000 + i));
            vm.deal(w, chunk * 2);
            vm.prank(w);
            pad.buy{value: chunk}(address(t), 0);
        }
        vm.clearMockedCalls();
        assertTrue(pad.getLaunch(address(t)).complete);
        assertFalse(pad.getLaunch(address(t)).graduated);
        uint256 bonus = pad.getLaunch(address(t)).bonus;
        uint256 raised = uint256(pad.getLaunch(address(t)).reserve) + bonus;
        uint256 c0 = pad.claimable(creator, address(0));
        uint256 p0 = pad.claimable(treasury, address(0));

        vm.recordLogs();
        pad.graduate(address(t));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paidQuote;
        bytes32 sig = keccak256("Graduated(address,bytes32,uint160,uint256,uint256,uint128)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == sig) {
                (, paidQuote,,) = abi.decode(logs[i].data, (uint160, uint256, uint256, uint128));
            }
        }
        uint256 excess = raised - paidQuote;
        assertGt(excess, 1 ether);
        uint256 toCreator = excess < bonus ? excess : bonus;
        assertEq(pad.claimable(creator, address(0)) - c0, toCreator);
        assertEq(pad.claimable(treasury, address(0)) - p0, excess - toCreator);
        assertGe(address(pad).balance, pad.claimable(creator, address(0)) + pad.claimable(treasury, address(0)));
        // the pool trades after graduation
        _routerBuy(alice, t, 1 ether);
    }

    // ---------------------------------------------------------------- L-2: rescue after a kill, orphan pot

    function test_rescueNthPotAfterDisable() public {
        (HookTokenV2 t, PoolKey memory key) = _one(nthPotId, _nthCfg(100, 1_000, 0.1 ether));
        PoolId id = _id(key);
        _routerBuy(bob, t, 1 ether);
        uint256 pot = nthPot.potOf(id).pot;
        assertGt(pot, 0);
        vm.expectRevert(LedgerModuleBase.NotDisabled.selector);
        nthPot.rescue(address(t));
        modules.disable(nthPotId);
        uint256 c0 = hook.claimable(creator, NATIVE);
        nthPot.rescue(address(this)); // unknown token: nothing to pay
        nthPot.rescue(address(t));
        assertEq(hook.claimable(creator, NATIVE) - c0, pot);
        assertEq(nthPot.potOf(id).pot, 0);
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
    }

    function test_rescueBuybackAndTimerPotAfterDisable() public {
        (HookTokenV2 t, PoolKey memory key) = _many(
            _ids2(buybackId, timerPotId), _cfgs2(_buybackCfg(500, 1_000 ether), _timerCfg(100, 7 days, 0.1 ether)), 100
        );
        PoolId id = _id(key);
        uint256 got = _routerBuy(bob, t, 5 ether);
        _routerSell(bob, t, got);
        uint256 saved = buyback.vaultOf(id).saved;
        uint256 pot = timerPot.potOf(id).pot;
        assertGt(saved, 0);
        assertGt(pot, 0);
        modules.disable(buybackId);
        modules.disable(timerPotId);
        uint256 c0 = hook.claimable(creator, NATIVE);
        buyback.rescue(address(t));
        timerPot.rescue(address(t));
        assertEq(hook.claimable(creator, NATIVE) - c0, saved + pot);
        assertEq(hook.claimable(address(buyback), NATIVE), 0);
        assertEq(hook.claimable(address(timerPot), NATIVE), 0);
    }

    function test_orphanNthPotGoesToCreator() public {
        (, PoolKey memory key) = _one(nthPotId, _nthCfg(100, 1_000, 0.1 ether));
        PoolId id = _id(key);
        uint256 pot = nthPot.potOf(id).pot;
        assertGt(pot, 0);
        uint256 c0 = hook.claimable(creator, NATIVE);
        vm.warp(vm.getBlockTimestamp() + 30 days - 1);
        nthPot.settle(id); // too early: nothing
        assertEq(nthPot.potOf(id).pot, pot);
        vm.warp(vm.getBlockTimestamp() + 1);
        nthPot.settle(id);
        assertEq(hook.claimable(creator, NATIVE) - c0, pot);
        assertEq(nthPot.potOf(id).pot, 0);
        assertEq(nthPot.accounted(address(0)), hook.claimable(address(nthPot), NATIVE));
    }

    // ---------------------------------------------------------------- L-3: referral sinks

    function test_referralRefusesProtocolAddresses() public {
        (HookTokenV2 t,) = _many(_ids2(referralId, lpId), _cfgs2(_referralCfg(900, 200), _lpCfg(100)), 100);
        address[8] memory bad = [
            address(0),
            address(1),
            ModuleCaps.BURN,
            address(hook),
            address(pad),
            address(PM),
            address(router),
            address(lpRewards)
        ];
        for (uint256 i; i < bad.length; ++i) {
            address buyer = address(uint160(0xBEEF00 + i));
            vm.deal(buyer, 2 ether);
            _routerBuyRef(buyer, t, 1 ether, bad[i]); // the buy goes through...
            assertEq(referral.referrerOf(buyer), address(0)); // ...and binds nothing
        }
        address ok = makeAddr("referrer");
        _routerBuyRef(alice, t, 1 ether, ok);
        assertEq(referral.referrerOf(alice), ok);
    }

    // ---------------------------------------------------------------- I-3: registry codehash

    function test_registryRecordsCodehash() public view {
        HookModuleRegistry.Module memory m = modules.getModule(nthPotId);
        assertEq(m.codehash, address(nthPot).codehash);
        assertFalse(modules.codehashChanged(nthPotId));
    }
}
