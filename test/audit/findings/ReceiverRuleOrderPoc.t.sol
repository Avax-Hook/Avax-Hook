// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AllowlistModule} from "../../../contracts/v2/modules/AllowlistModule.sol";
import {HolderGatedModule} from "../../../contracts/v2/modules/HolderGatedModule.sol";
import {MockRewardToken} from "../../v2/NewModulesBase.t.sol";
import {ListsAccessBase} from "../../v2/ListsAccessBase.t.sol";

/// An LP contract that owns a full-range position of the pool and plays the order-dependent allowance games.
///   mode 0: seed the position (paid from its own tokens / AVAX)
///   mode 1: buy, remove the position, re-add it (net zero), take the bought tokens to `to`
///   mode 2: remove, take the removed tokens to `to` (uses the allowance), re-add funded by a buy (leftover kept as 6909)
///   mode 3: honest: remove and take to `to`
contract LpReorderer is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function run(uint8 mode, PoolKey calldata key, uint256 amountIn, int256 liq, address to) external {
        pm.unlock(abi.encode(mode, key, amountIn, liq, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint8 mode, PoolKey memory key, uint256 amountIn, int256 liq, address to) =
            abi.decode(data, (uint8, PoolKey, uint256, int256, address));
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), liq, 0);
        if (mode == 0) {
            pm.modifyLiquidity(key, p, "");
        } else if (mode == 1) {
            pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
            p.liquidityDelta = -liq;
            pm.modifyLiquidity(key, p, "");
            p.liquidityDelta = liq;
            pm.modifyLiquidity(key, p, "");
        } else if (mode == 2) {
            p.liquidityDelta = -liq;
            pm.modifyLiquidity(key, p, "");
            pm.take(key.currency1, to, uint256(pm.currencyDelta(address(this), key.currency1)));
            p.liquidityDelta = liq;
            pm.modifyLiquidity(key, p, "");
            pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), ""); // covers the add
        } else {
            p.liquidityDelta = -liq;
            pm.modifyLiquidity(key, p, "");
        }
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        else if (d0 > 0) pm.take(key.currency0, address(this), uint256(d0));
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        if (d1 < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(-d1));
            pm.settle();
        } else if (d1 > 0) {
            if (mode == 2) pm.mint(address(this), CurrencyLibrary.toId(key.currency1), uint256(d1));
            else pm.take(key.currency1, to, uint256(d1));
        }
        return "";
    }
}

/// Finding: the "no allowance if this tx added liquidity" rule only looked at adds BEFORE the removal. An LP
/// could remove (allowance), re-add (net zero) and take a buy to a non-qualifying address: a free allowance in
/// every transaction. Fixed in ReceiverRuleBase: an add after a removal wipes the allowance, and reverts if
/// some of it was already used.
/// forge-config: default.isolate = true
contract ReceiverRuleOrderPoc is ListsAccessBase {
    AllowlistModule alw;
    uint32 alwId;
    HolderGatedModule hg;
    uint32 hgId;
    MockRewardToken gateT;
    LpReorderer lp;
    int256 constant LIQ = 1e21; // ~4.7e23 tokens: more than a 1 AVAX buy pays out

    function setUp() public override {
        super.setUp();
        alw = new AllowlistModule(address(hook));
        alwId = modules.addModule(address(alw), '{"name":"Allowlist"}');
        hg = new HolderGatedModule(address(hook));
        hgId = modules.addModule(address(hg), '{"name":"Holder-gated"}');
        gateT = new MockRewardToken();
        _allowQuote(address(gateT));
        for (uint256 i; i < 120; ++i) gateT.mint(_holder(i), 100 ether);
        lp = new LpReorderer(PM);
        vm.deal(address(lp), 100 ether);
    }

    function _allowlisted() internal returns (HookTokenV2 t, PoolKey memory key) {
        address[] memory list = new address[](120);
        for (uint256 i; i < 120; ++i) list[i] = _holder(i);
        t = _launch(_one(alwId), _oneCfg(abi.encode(AllowlistModule.Config(list, bytes32(0), 0))), 0);
        key = _graduateN(t, 40, 0);
        _seed(t, key);
    }

    function _gated() internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(_one(hgId), _oneCfg(abi.encode(HolderGatedModule.Config(address(gateT), 100 ether, 0))), 0);
        key = _graduateN(t, 40, 0);
        _seed(t, key);
    }

    function _seed(HookTokenV2 t, PoolKey memory key) internal {
        deal(address(t), address(lp), 5_000_000 ether);
        lp.run(0, key, 0, LIQ, address(0));
    }

    function test_allowlist_removeReaddBuyRefused() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        vm.expectRevert();
        lp.run(1, key, 1 ether, LIQ, bob);
        assertEq(t.balanceOf(bob), 0);
        // since the 2026-11-12 claims-bypass guard the direct PoolManager buy inside the rebalance is refused for
        // a listed wallet too (RouterOnly) while the list applies
        uint256 b1 = t.balanceOf(_holder(3));
        try lp.run(1, key, 1 ether, LIQ, _holder(3)) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        assertEq(t.balanceOf(_holder(3)), b1, "nothing bought");
    }

    function test_allowlist_removeTakeReaddRefused() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        vm.expectRevert(); // the re-add after the allowance paid bob reverts
        lp.run(2, key, 5 ether, LIQ, bob);
        assertEq(t.balanceOf(bob), 0);
        // listed receiver: refused too since the 2026-11-12 claims-bypass guard (direct PoolManager buy, RouterOnly)
        uint256 b2 = t.balanceOf(_holder(4));
        try lp.run(2, key, 5 ether, LIQ, _holder(4)) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        assertEq(t.balanceOf(_holder(4)), b2, "nothing bought");
    }

    function test_allowlist_honestRemovalToAnyone() public {
        (HookTokenV2 t, PoolKey memory key) = _allowlisted();
        lp.run(3, key, 0, LIQ, bob);
        assertGt(t.balanceOf(bob), 0);
    }

    function test_holderGated_removeReaddBuyRefused() public {
        (HookTokenV2 t, PoolKey memory key) = _gated();
        vm.expectRevert();
        lp.run(1, key, 1 ether, LIQ, bob);
        vm.expectRevert();
        lp.run(2, key, 5 ether, LIQ, bob);
        assertEq(t.balanceOf(bob), 0);
        lp.run(3, key, 0, LIQ, bob);
        assertGt(t.balanceOf(bob), 0);
    }
}
