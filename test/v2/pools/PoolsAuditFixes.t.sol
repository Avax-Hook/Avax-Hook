// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {PoolCoordinatorTest} from "./PoolCoordinator.t.sol";
import {AvaxHookV2} from "../../../contracts/v2/AvaxHookV2.sol";
import {PoolCoordinatorV1} from "../../../contracts/v2/pools/PoolCoordinatorV1.sol";
import {PoolRouterV1} from "../../../contracts/v2/pools/PoolRouterV1.sol";
import {IPositionManagerLite} from "../../../contracts/v2/pools/PoolCoordinatorV1.sol";
import {NthBuyPotModule} from "../../../contracts/v2/modules/NthBuyPotModule.sol";
import {LastBuyerPotModule} from "../../../contracts/v2/modules/LastBuyerPotModule.sol";
import {LedgerModuleBase} from "../../../contracts/v2/modules/LedgerModuleBase.sol";
import {NthBuyPotPoolsModule} from "../../../contracts/v2/pools/modules/NthBuyPotPoolsModule.sol";
import {LastBuyerPotPoolsModule} from "../../../contracts/v2/pools/modules/LastBuyerPotPoolsModule.sol";

/// Swaps straight through the PoolManager (no router): proves the hook itself refuses partial fills.
contract DirectSwapper is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function buy(PoolKey calldata key, uint256 amountIn) external payable returns (uint256 out) {
        out = abi.decode(pm.unlock(abi.encode(key, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta d = pm.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), ""
        );
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        uint256 out = uint256(uint128(d.amount1()));
        pm.take(key.currency1, address(this), out);
        return abi.encode(out);
    }

    receive() external payable {}
}

/// Regression tests for the pools-profile audit fixes (M-1, L-1..L-4, I-2, I-5).
contract PoolsAuditFixesTest is PoolCoordinatorTest {
    using StateLibrary for IPoolManager;

    uint32 lastId;

    function setUp() public override {
        super.setUp();
        lastId = modules.addModule(address(new LastBuyerPotPoolsModule(address(hook))), '{"name":"Last buyer pot"}');
    }

    function _openWith(uint32 id, bytes memory cfg, uint256 seedToken, uint256 seedQuote) internal returns (PoolId pid, uint256 nft, PoolKey memory key) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        (ids[0], cfgs[0]) = (id, cfg);
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, seedToken, seedQuote);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        (pid, nft) = coord.openPool{value: coord.openFeeFor(JOE, address(0)) + a.seedQuote}(a);
        vm.stopPrank();
        key = coord.poolKeyOf(pid);
    }

    /// The opener (or the last LP) pulls the whole position out.
    function _withdrawAll(uint256 nft, PoolKey memory key) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(nft, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, opener);
        vm.prank(opener);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _partialFillError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(AvaxHookV2.PartialFillNotAllowed.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ---------------------------------------------------------------- M-1

    /// The audit PoC: a "100 AVAX buy" in a pool whose liquidity is gone used to count in full for the pot
    /// while spending ~2.3 AVAX and pushing the price to MIN. It now reverts and changes nothing.
    function test_m1_emptyPoolBuyReverts() public {
        (PoolId id, uint256 nft, PoolKey memory key) =
            _openWith(potId, abi.encode(NthBuyPotModule.Config(200, 2, 50 ether)), 10_000 ether, 10 ether);
        _withdrawAll(nft, key);
        assertEq(PM.getLiquidity(id), 0, "liquidity gone");
        (uint160 priceBefore,,,) = PM.getSlot0(id);

        uint256 before = alice.balance;
        vm.prank(alice);
        vm.expectRevert(_partialFillError());
        router.swap{value: 100 ether}(key, true, 100 ether, 0, address(0), block.timestamp, "");
        assertEq(alice.balance, before, "nothing spent");

        // the 1-wei price push is closed too
        vm.prank(alice);
        vm.expectRevert(_partialFillError());
        router.swap{value: 1}(key, true, 1, 0, address(0), block.timestamp, "");
        (uint160 priceAfter,,,) = PM.getSlot0(id);
        assertEq(priceAfter, priceBefore, "price unchanged");
        assertEq(NthBuyPotModule(hook.poolInfo(id).modules[0]).potOf(id).buyCount, 0, "no buy counted");

        // the quote reports it instead of a fake result
        (uint256 out, uint256 used, bool wouldRevert,) = router.quote(key, true, 100 ether, alice, address(0), "");
        assertTrue(wouldRevert);
        assertEq(out, 0);
        assertEq(used, 0);
    }

    /// Full-range liquidity absorbs any input before the price limit (the limit is never reached with
    /// liquidity > 0), so even a thin pool fills completely: partial fills only happen in empty pools.
    function test_m1_thinPoolFillsCompletely() public {
        (PoolId id,, PoolKey memory key) =
            _openWith(potId, abi.encode(NthBuyPotModule.Config(200, 2, 50 ether)), 1e12, 1e9);
        assertGt(PM.getLiquidity(id), 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        router.swap{value: 100 ether}(key, true, 100 ether, 0, address(0), block.timestamp, "");
        assertEq(before - alice.balance, 100 ether, "whole input used");
    }

    /// The hook refuses partial fills by itself, also for swaps that don't go through the router.
    function test_m1_hookRefusesDirectPartialFill() public {
        (PoolId id, uint256 nft, PoolKey memory key) =
            _openWith(potId, abi.encode(NthBuyPotModule.Config(200, 2, 50 ether)), 10_000 ether, 10 ether);
        DirectSwapper s = new DirectSwapper(PM);
        vm.deal(address(s), 10 ether);
        uint256 out = s.buy(key, 1 ether); // a full fill passes
        assertGt(out, 0);
        _withdrawAll(nft, key);
        assertEq(PM.getLiquidity(id), 0);
        vm.expectRevert(_partialFillError());
        s.buy(key, 1 ether);
    }

    /// A full fill nets exactly amountIn on the router (no refund branch left).
    function test_m1_fullFillPaysExactly() public {
        (,, PoolKey memory key) = _openJoeAvax(100);
        uint256 before = alice.balance;
        _buy(alice, key, 1 ether);
        assertEq(before - alice.balance, 1 ether);
    }

    // ---------------------------------------------------------------- L-1

    function test_l1_rescueByPoolReachesEveryPoolOfAToken() public {
        bytes memory cfg = abi.encode(NthBuyPotModule.Config(200, 1_000, 0.01 ether));
        (PoolId id1,, PoolKey memory k1) = _openWith(potId, cfg, 10_000 ether, 10 ether);
        (PoolId id2,, PoolKey memory k2) = _openWith(potId, cfg, 10_000 ether, 10 ether);
        _buy(alice, k1, 1 ether);
        vm.roll(block.number + 1);
        _buy(alice, k2, 2 ether);
        NthBuyPotPoolsModule pot = NthBuyPotPoolsModule(hook.poolInfo(id1).modules[0]);
        pot.reconcile();
        assertEq(pot.potOf(id1).pot, 0.02 ether);
        assertEq(pot.potOf(id2).pot, 0.04 ether);

        vm.expectRevert(LedgerModuleBase.NotDisabled.selector);
        pot.rescuePool(id1);
        modules.disable(potId);
        vm.expectRevert(NthBuyPotPoolsModule.UseRescuePool.selector);
        pot.rescue(JOE);

        Currency avax = Currency.wrap(address(0));
        uint256 c0 = hook.claimable(opener, avax);
        pot.rescuePool(id1); // the older pool, unreachable through rescue(token) before
        pot.rescuePool(id2);
        assertEq(hook.claimable(opener, avax) - c0, 0.06 ether);
        assertEq(pot.potOf(id1).pot, 0);
        assertEq(pot.potOf(id2).pot, 0);
    }

    // ---------------------------------------------------------------- L-2

    function test_l2_openFeeGrowsWithPairCount() public {
        assertEq(coord.openFeeFor(JOE, address(0)), OPEN_FEE);
        for (uint256 i; i < 10; ++i) {
            _openJoeAvax(0);
        }
        assertEq(coord.pairCount(JOE, address(0)), 10);
        assertEq(coord.openFeeFor(JOE, address(0)), 2 * OPEN_FEE, "11th pool costs 2x");
        assertEq(coord.openFeeFor(address(0), JOE), 2 * OPEN_FEE, "same in either orientation");
        assertEq(coord.openFeeFor(JOE, USDC), OPEN_FEE, "other pairs unaffected");

        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        vm.expectRevert(PoolCoordinatorV1.BadValue.selector);
        coord.openPool{value: OPEN_FEE + a.seedQuote}(a);
        coord.openPool{value: 2 * OPEN_FEE + a.seedQuote}(a);
        vm.stopPrank();
        assertEq(coord.feesOwed(), 12 * OPEN_FEE);
    }

    // ---------------------------------------------------------------- L-3

    function test_l3_baseFeeAndPotCaps() public {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        a.core.baseFeePips = 10_001;
        vm.prank(opener);
        vm.expectRevert(PoolCoordinatorV1.BaseFeeTooHigh.selector);
        coord.openPool{value: OPEN_FEE + a.seedQuote}(a);

        NthBuyPotPoolsModule nth = NthBuyPotPoolsModule(modules.getModule(potId).impl);
        vm.expectRevert();
        nth.validateConfig(abi.encode(NthBuyPotModule.Config(201, 2, 1)));
        nth.validateConfig(abi.encode(NthBuyPotModule.Config(200, 2, 1)));
        LastBuyerPotPoolsModule last = LastBuyerPotPoolsModule(modules.getModule(lastId).impl);
        vm.expectRevert();
        last.validateConfig(abi.encode(LastBuyerPotModule.Config(201, 60, 1)));

        // and through openPool
        uint32[] memory one = new uint32[](1);
        bytes[] memory oneCfg = new bytes[](1);
        (one[0], oneCfg[0]) = (potId, abi.encode(NthBuyPotModule.Config(1_000, 2, 1)));
        a = _args(JOE, address(0), 0, one, oneCfg, 10_000 ether, 10 ether);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        vm.expectRevert();
        coord.openPool{value: OPEN_FEE + a.seedQuote}(a);
        vm.stopPrank();
    }

    /// An unreachable minBuy no longer turns the pot into a creator fee: orphaned pots go to the protocol.
    function test_l3_orphanedPotsGoToProtocolNotOpener() public {
        Currency avax = Currency.wrap(address(0));
        (PoolId idL,, PoolKey memory kL) =
            _openWith(lastId, abi.encode(LastBuyerPotModule.Config(200, 60, type(uint96).max)), 10_000 ether, 10 ether);
        (PoolId idN,, PoolKey memory kN) =
            _openWith(potId, abi.encode(NthBuyPotModule.Config(200, 2, type(uint96).max)), 10_000 ether, 10 ether);
        _buy(alice, kL, 1 ether);
        _buy(alice, kN, 1 ether);
        vm.warp(block.timestamp + 30 days);
        LastBuyerPotPoolsModule(hook.poolInfo(idL).modules[0]).settle(idL);
        NthBuyPotPoolsModule(hook.poolInfo(idN).modules[0]).settle(idN);
        assertEq(hook.claimable(treasury, avax), 0.04 ether, "both pots to the protocol recipient");
        assertEq(hook.claimable(opener, avax), 0, "nothing to the opener");
    }

    // ---------------------------------------------------------------- I-5

    function test_i5_deployedPaused() public {
        PoolCoordinatorV1 c = new PoolCoordinatorV1(PM, hook, POSM, PERMIT2, address(this), treasury, OPEN_FEE);
        assertTrue(c.paused());
    }
}
