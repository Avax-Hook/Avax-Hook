// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AllowlistModule} from "../../../contracts/v2/modules/AllowlistModule.sol";
import {BuyerRewardsModule} from "../../../contracts/v2/modules/BuyerRewardsModule.sol";
import {ListsAccessBase} from "../../v2/ListsAccessBase.t.sol";

/// Swap-and-take buyer (native quote, token is currency1).
contract DeltaTaker is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function buy(PoolKey calldata key, uint256 amountIn, address to) external {
        pm.unlock(abi.encode(key, amountIn, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        BalanceDelta d = pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        pm.take(key.currency1, to, uint256(uint128(d.amount1())));
        return "";
    }
}

/// An LP that owns its own full-range position. add: deposit; remove: withdraw, tokens to `to`.
contract DeltaLp is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function act(PoolKey calldata key, int256 liq, address to) external {
        pm.unlock(abi.encode(key, liq, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int256 liq, address to) = abi.decode(data, (PoolKey, int256, address));
        pm.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), liq, 0), "");
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        if (d0 > 0) pm.take(key.currency0, address(this), uint256(d0));
        if (d1 < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(-d1));
            pm.settle();
        }
        if (d1 > 0) pm.take(key.currency1, to, uint256(d1));
        return "";
    }
}

/// Two independent operations bundled in ONE transaction (an ERC-4337 bundle, a batching relayer, a multicall):
/// an honest LP's withdrawal to its own (qualifying) address, then an unrelated buyer's swap.
contract DeltaBundler {
    function run(DeltaLp lp, PoolKey calldata key, int256 liq, address lpTo, DeltaTaker taker, uint256 buyIn, address buyTo)
        external
    {
        lp.act(key, -liq, lpTo);
        taker.buy(key, buyIn, buyTo);
    }
}

contract DeltaFinal is ListsAccessBase {
    AllowlistModule alw;
    uint32 alwId;
    BuyerRewardsModule br;
    uint32 brId;

    function setUp() public override {
        super.setUp();
        alw = new AllowlistModule(address(hook));
        alwId = modules.addModule(address(alw), '{"name":"Allowlist"}');
        br = new BuyerRewardsModule(address(hook));
        brId = modules.addModule(address(br), '{"name":"BuyerRewards"}');
    }

    function _list() internal pure returns (address[] memory list) {
        list = new address[](120);
        for (uint256 i; i < 120; ++i) list[i] = address(uint160(0xB0B000 + i));
    }

    /// D-1: the new "payouts FROM a module of this pool are excused" rule launders tokens past a receiver rule
    /// when a pool module holds launched tokens and pays them to caller-chosen addresses. BuyerRewards with the
    /// launched token itself as the reward token (address predictable: the factory deploys with CREATE): the
    /// creator funds the vault and withdraws "free" rewards to a wallet the allowlist refuses; any rewarded buyer
    /// can also claim(token, anyWallet).
    function test_delta_moduleSenderLaundersPastAllowlist() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        uint32[] memory ids = new uint32[](2);
        (ids[0], ids[1]) = (alwId, brId);
        bytes[] memory cfgs = new bytes[](2);
        cfgs[0] = abi.encode(AllowlistModule.Config(_list(), bytes32(0), 0));
        cfgs[1] = abi.encode(BuyerRewardsModule.Config(predicted, 1 ether, 1 ether, 0, 0));
        HookTokenV2 t = _launch(ids, cfgs, 0);
        assertEq(address(t), predicted, "self reward token");
        _graduateN(t, 40, 0);

        // control: the creator (an exempt receiver) can't hand tokens to a non-listed wallet directly
        deal(address(t), creator, 10_000_000 ether);
        vm.prank(creator);
        vm.expectRevert();
        t.transfer(bob, 1_000 ether);

        // regression: payouts from a pool module are checked like any receive, so the vault can't launder it
        vm.startPrank(creator);
        t.approve(address(br), type(uint256).max);
        br.fund(address(t), 10_000_000 ether);
        vm.expectRevert();
        br.withdraw(address(t), 10_000_000 ether, bob);
        vm.stopPrank();
        assertFalse(alw.canReceive(address(t), bob));
        assertEq(t.balanceOf(bob), 0, "non-listed wallet received nothing");
    }

    /// D-2: the LP allowance is per transaction, not per remover/receiver. An honest LP that withdraws to a
    /// QUALIFYING address leaves its whole allowance unused, and any later PoolManager outflow in the same
    /// transaction (an unrelated buyer bundled in the same tx) spends it.
    /// forge-config: default.isolate = true
    function test_delta_leftoverAllowanceUsedByOtherOpInSameTx() public {
        HookTokenV2 t = _launch(_one(alwId), _oneCfg(abi.encode(AllowlistModule.Config(_list(), bytes32(0), 0))), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        DeltaLp lp = new DeltaLp(PM);
        DeltaTaker taker = new DeltaTaker(PM);
        vm.deal(address(lp), 100 ether);
        vm.deal(address(taker), 100 ether);
        deal(address(t), address(lp), 50_000_000 ether);
        lp.act(key, 1e20, address(0)); // earlier transaction: deposit

        // control: the non-listed buy alone is refused
        vm.expectRevert();
        taker.buy(key, 0.01 ether, bob);

        // D-2 was open until 2026-11-12: the bundled direct buy spent the honest LP's leftover allowance. The
        // claims-bypass guard now refuses the direct PoolManager buy itself (RouterOnly) while the list applies,
        // so the bundle reverts and the non-listed wallet gets nothing. (A router buy is checked per receiver.)
        DeltaBundler b = new DeltaBundler();
        try b.run(lp, key, 1e20, _holder(5), taker, 0.01 ether, bob) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        assertEq(t.balanceOf(bob), 0, "non-listed wallet bought nothing");
    }
}
