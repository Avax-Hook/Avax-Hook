// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AllowlistModule} from "../../../contracts/v2/modules/AllowlistModule.sol";
import {PlagueModule} from "../../../contracts/v2/modules/PlagueModule.sol";
import {BalanceRead} from "../../../contracts/v2/modules/lib/BalanceRead.sol";
import {ListsAccessBase} from "../../v2/ListsAccessBase.t.sol";

/// Native-quote buyer that delivers to `to`. mode 0: swap, then take the output to `to` (what every router
/// does). mode 1: take `pre` tokens to `to` BEFORE the swap (flash accounting), swap, keep the rest as 6909.
contract ListsTaker is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function buy(PoolKey calldata key, uint256 amountIn, address to, uint8 mode, uint256 pre) external payable {
        pm.unlock(abi.encode(key, amountIn, to, mode, pre));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, address to, uint8 mode, uint256 pre) =
            abi.decode(data, (PoolKey, uint256, address, uint8, uint256));
        if (mode == 1) pm.take(key.currency1, to, pre);
        BalanceDelta d =
            pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        uint256 out = uint256(uint128(d.amount1()));
        if (mode == 0) pm.take(key.currency1, to, out);
        else pm.mint(address(this), CurrencyLibrary.toId(key.currency1), out - pre);
        return "";
    }
}

/// One unlock: buy, park the output as liquidity in the same pool, remove it, take the tokens to `to`.
contract ListsLaunderer is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function run(PoolKey calldata key, uint256 amountIn, int256 liq, address to) external payable {
        pm.unlock(abi.encode(key, amountIn, liq, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, int256 liq, address to) = abi.decode(data, (PoolKey, uint256, int256, address));
        pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        ModifyLiquidityParams memory p = ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), liq, 0);
        pm.modifyLiquidity(key, p, "");
        p.liquidityDelta = -liq;
        pm.modifyLiquidity(key, p, "");
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        if (d1 > 0) pm.take(key.currency1, to, uint256(d1));
        return "";
    }
}

contract ListsIsEoaHarness {
    function dirty(address a) external view returns (bool) {
        assembly {
            let p := mload(0x40)
            mstore(p, not(0))
        }
        return BalanceRead.isEoa(a);
    }
}

contract ListsFinal is ListsAccessBase {
    using StateLibrary for IPoolManager;

    AllowlistModule alw;
    uint32 alwId;
    PlagueModule pl;
    uint32 plId;
    ListsTaker taker;

    function setUp() public override {
        super.setUp();
        alw = new AllowlistModule(address(hook));
        alwId = modules.addModule(address(alw), '{"name":"Allowlist"}');
        pl = new PlagueModule(address(hook));
        plId = modules.addModule(address(pl), '{"name":"Plague"}');
        taker = new ListsTaker(PM);
        vm.deal(address(taker), 1_000 ether);
    }

    function _allowlisted() internal returns (HookTokenV2 t, PoolKey memory key) {
        address[] memory list = new address[](120);
        for (uint256 i; i < 120; ++i) list[i] = _holder(i);
        t = _launch(_one(alwId), _oneCfg(abi.encode(AllowlistModule.Config(list, bytes32(0), 0))), 0);
        key = _graduateN(t, 40, 0);
    }

    /// A hookless v4 pool of the same token, seeded by an ordinary holder.
    function _shadowPool(HookTokenV2 t, PoolKey memory key, address lpOwner) internal returns (PoolKey memory k2) {
        k2 = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        PM.initialize(k2, sp);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        vm.deal(lpOwner, lpOwner.balance + 50 ether);
        vm.startPrank(lpOwner);
        t.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 20 ether}(
            k2, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e18, 0), ""
        );
        vm.stopPrank();
    }

    /// Control: the pool buy to a non-listed wallet is refused.
    function test_lists_control_buyRefused() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        vm.deal(bob, 1 ether);
        _buyReverts(bob, t, 1 ether);
        vm.expectRevert();
        taker.buy(key, 1 ether, bob, 0, 0);
        assertEq(t.balanceOf(bob), 0);
    }

    /// F-1 fixed: taking the output BEFORE the swap in the same unlock is checked like any PoolManager outflow.
    function test_lists_takeBeforeSwapBypass() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        assertFalse(alw.canReceive(address(t), bob));
        vm.expectRevert();
        taker.buy(key, 1 ether, bob, 1, 1_000 ether);
        assertEq(t.balanceOf(bob), 0);
        // since the 2026-11-12 claims-bypass guard a listed wallet can't buy that way either (RouterOnly) while
        // the list applies; it buys through the router
        try taker.buy(key, 1 ether, _holder(1), 1, 1_000 ether) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        assertGt(_routerBuy(_holder(1), t, 1 ether), 0);
    }

    /// F-2 fixed: a hookless v4 pool of the token: its outputs leave the PoolManager and are checked as buys.
    function test_lists_shadowPoolBypass_allowlist() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        PoolKey memory k2 = _shadowPool(t, key, _holder(0));
        vm.expectRevert();
        taker.buy(k2, 1 ether, bob, 0, 0);
        assertEq(t.balanceOf(bob), 0);
        taker.buy(k2, 1 ether, _holder(2), 0, 0); // listed wallets buy there fine
    }

    function test_lists_shadowPoolBypass_plague() public {
        HookTokenV2 t = _launch(_one(plId), _oneCfg(abi.encode(PlagueModule.Config(1_000 ether, 0))), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        vm.expectRevert();
        taker.buy(key, 1 ether, bob, 0, 0);
        PoolKey memory k2 = _shadowPool(t, key, _holder(0));
        vm.expectRevert();
        taker.buy(k2, 1 ether, bob, 0, 0);
        assertEq(t.balanceOf(bob), 0);
        // a contract can't buy for it either (PoolManager -> uninfected contract), nor hand tokens on (an
        // uninfected sender), even tokens an infected holder sent it
        vm.expectRevert();
        taker.buy(k2, 1 ether, address(this), 0, 0);
        _send(t, _holder(0), address(this), 2_000 ether);
        assertFalse(pl.infected(address(t), address(this)));
        vm.expectRevert(abi.encodeWithSelector(PlagueModule.NotInfected.selector, bob));
        t.transfer(bob, 2_000 ether);
    }

    function _addLp(PoolKey memory key, HookTokenV2 t, address who) internal returns (PoolModifyLiquidityTest lp) {
        lp = new PoolModifyLiquidityTest(PM);
        vm.deal(who, who.balance + 20 ether);
        vm.startPrank(who);
        t.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 10 ether}(
            key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e18, 0), ""
        );
        vm.stopPrank();
    }

    /// A non-listed LP of THIS pool collects fees and removes its liquidity (allowance), but can't buy.
    /// forge-config: default.isolate = true
    function test_lists_nonQualifyingLpWithdrawsAndCollects() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        address lpUser = makeAddr("lpUser");
        // a non-listed holder (seeded directly; the allowlist only checks receives)
        deal(address(t), lpUser, 5_000_000 ether);
        PoolModifyLiquidityTest lp = _addLp(key, t, lpUser);
        // fees accrue to the position (buys and sells by listed wallets)
        for (uint256 i; i < 3; ++i) {
            uint256 got = _routerBuy(_holder(i), t, 5 ether);
            _routerSell(_holder(i), t, got);
        }
        uint256 b0 = t.balanceOf(lpUser);
        vm.prank(lpUser);
        lp.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 0, 0), "");
        assertGt(t.balanceOf(lpUser), b0, "fee collect paid tokens");
        b0 = t.balanceOf(lpUser);
        vm.prank(lpUser);
        lp.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -1e18, 0), "");
        assertGt(t.balanceOf(lpUser), b0, "removal paid tokens");
        vm.deal(lpUser, 1 ether);
        _buyReverts(lpUser, t, 1 ether);
    }

    /// Hookless-pool LPs that fail the rule can't withdraw to themselves (documented); to a listed address they can.
    function test_lists_shadowPoolLpMustWithdrawToQualifying() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        address lpUser = makeAddr("lpUser");
        deal(address(t), lpUser, 5_000_000 ether);
        PoolKey memory k2 = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        PM.initialize(k2, sp);
        PoolModifyLiquidityTest lp = _addLp(k2, t, lpUser);
        vm.prank(lpUser);
        vm.expectRevert();
        lp.modifyLiquidity(k2, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), -1e18, 0), "");
    }

    /// isEoa with dirty memory past the free pointer: a 7702 designator must still read as an EOA.
    function test_lists_isEoaDirtyMemory() public {
        address w = makeAddr("delegated");
        vm.etch(w, abi.encodePacked(hex"ef0100", address(0x1234)));
        ListsIsEoaHarness h = new ListsIsEoaHarness();
        assertTrue(h.dirty(w));
    }

    /// No LP allowance in a transaction that also added liquidity to this pool: a buy parked as liquidity and
    /// pulled out in the same unlock is still checked.
    function test_lists_sameTxAddRemoveLaunderingRefused() public {
        (, PoolKey memory key) = _allowlisted();
        ListsLaunderer l = new ListsLaunderer(PM);
        vm.deal(address(l), 100 ether);
        vm.expectRevert();
        l.run(key, 1 ether, 1e15, bob);
        // since the 2026-11-12 claims-bypass guard the direct PoolManager swap is refused for anyone while the list
        // applies, listed receivers too (RouterOnly)
        try l.run(key, 1 ether, 1e15, _holder(3)) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
    }
}
