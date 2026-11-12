// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";

/// Swaps on the PoolManager directly (no router hookData), like an outside searcher.
contract FixSwapper is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function swap(PoolKey calldata key, bool buy, int256 amt) external {
        pm.unlock(abi.encode(key, buy, amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool buy, int256 amt) = abi.decode(data, (PoolKey, bool, int256));
        pm.swap(key, SwapParams(buy, amt, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 owe = uint256(-d);
            if (c.isAddressZero()) {
                pm.settle{value: owe}();
            } else {
                pm.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(pm), owe);
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}

/// Regression tests for the final-audit hook findings (M-1, L-1, L-2, L-3, I-1, I-3), on an Avalanche fork.
contract HookFixesTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant AVAX_USD = 0x0A77230d17318075983913bC2145DB16C7366156;
    Currency constant NATIVE = Currency.wrap(address(0));

    AvaxHook hook;
    HookLaunchpad pad;
    AvaxHookRouter router;
    QuoteRegistry registry;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeperBot = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(AvaxHook).creationCode, abi.encode(address(PM), address(this)));
        hook = new AvaxHook{salt: salt}(PM, address(this));
        HookTokenFactory factory = new HookTokenFactory();
        registry = new QuoteRegistry(address(this));
        registry.setQuote(address(0), true, AVAX_USD);
        registry.setFdv(250e8, 5_000e8);
        pad = new HookLaunchpad(PM, hook, factory, registry, address(this), treasury);
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        router = new AvaxHookRouter(PM, pad);
        hook.bindRouter(address(router));
        hook.setKeeper(keeperBot);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(creator, 100 ether);
    }

    function _grad(AvaxHook.HookConfig memory c) internal returns (HookToken t, PoolKey memory key) {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "R";
        a.symbol = "R";
        a.hook = c;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookToken(pad.launch{value: fee}(a));
        vm.prank(alice);
        pad.buy{value: 200 ether}(address(t), 0);
        key = pad.poolKey(address(t));
    }

    function _buybackCfg() internal pure returns (AvaxHook.HookConfig memory c) {
        c.buybackBps = 100;
        c.buybackMaxSpend = 30 ether;
    }

    /// Fills the buyback budget with round trips, then lets the reference price age.
    function _fillBuyback(HookToken t) internal {
        vm.startPrank(alice);
        t.approve(address(router), type(uint256).max);
        uint256 got;
        for (uint256 i; i < 40; ++i) {
            got = router.sell(address(t), 300_000_000 ether, 0, block.timestamp);
            router.buy{value: got}(address(t), got, 0, address(0), block.timestamp);
        }
        vm.stopPrank();
        vm.roll(block.number + 2 * uint256(hook.REF_MIN_AGE_BLOCKS()) + 1);
        vm.prank(alice);
        router.buy{value: 0.01 ether}(address(t), 0.01 ether, 0, address(0), block.timestamp); // checkpoint
        vm.roll(block.number + hook.REF_MIN_AGE_BLOCKS());
    }

    // M-1: pump in block N, buyback in N+1, dump (assuming the attacker could even predict the keeper's
    // block). The aged reference refuses buybacks after any real pump; what is left for a tiny pump on a
    // zero-LP-fee pool is generic sandwich dust, well under 1% of the buyback (the PoC's pre-fix
    // profit grew with the pump size).
    function test_M1_crossBlockSandwichUnprofitable() public {
        (HookToken t, PoolKey memory key) = _grad(_buybackCfg());
        _fillBuyback(t);
        assertGt(hook.poolState(key.toId()).buybackWei, 3 ether);
        FixSwapper j = new FixSwapper(PM);
        vm.deal(address(j), 1_000 ether);
        bool tokenIs1 = Currency.unwrap(key.currency1) == address(t);
        for (uint256 a = 0.125 ether; a <= 80 ether; a *= 2) {
            uint256 snap = vm.snapshotState();
            uint256 a0 = address(j).balance;
            j.swap(key, tokenIs1, -int256(a)); // block N: pump
            vm.roll(block.number + 1);
            uint256 spent;
            vm.prank(keeperBot);
            try hook.executeBuyback(key) returns (uint256 s, uint256) {
                spent = s;
            } catch {}
            j.swap(key, !tokenIs1, -int256(t.balanceOf(address(j)))); // dump into it
            int256 profit = int256(address(j).balance) - int256(a0);
            console2.log("pump / buyback spent", a, spent);
            console2.logInt(profit);
            if (a >= 2 ether) assertEq(spent, 0); // a pump past the reference bound gets nothing
            if (profit > 0) assertLt(uint256(profit), spent / 100);
            vm.revertToState(snap);
        }
    }

    // M-1: only the keeper (or the deployer) can run a buyback, and only the deployer sets the keeper.
    function test_M1_keeperOnly() public {
        (HookToken t, PoolKey memory key) = _grad(_buybackCfg());
        _fillBuyback(t);
        vm.prank(alice);
        vm.expectRevert(AvaxHook.NotKeeper.selector);
        hook.executeBuyback(key);
        vm.prank(alice);
        vm.expectRevert(AvaxHook.NotKeeper.selector);
        hook.setKeeper(alice);
        vm.prank(keeperBot);
        (uint256 spent, uint256 burned) = hook.executeBuyback(key);
        assertGt(spent, 0);
        assertGt(burned, 0);
    }

    // L-1: a dust swap earlier in the same block no longer blocks the buyback.
    function test_L1_dustSwapCantBlockBuyback() public {
        (HookToken t, PoolKey memory key) = _grad(_buybackCfg());
        _fillBuyback(t);
        vm.prank(bob);
        router.buy{value: 1}(address(t), 1, 0, address(0), block.timestamp);
        vm.prank(keeperBot);
        (uint256 spent,) = hook.executeBuyback(key);
        assertGt(spent, 0);
    }

    // L-2: the first referrer is bound for good; later ones (a buyer's second wallet) are ignored.
    function test_L2_stickyReferral() public {
        AvaxHook.HookConfig memory c;
        c.creatorFeeBps = 100;
        c.referralBps = 50;
        (HookToken t,) = _grad(c);
        vm.prank(bob);
        router.buy{value: 10 ether}(address(t), 10 ether, 0, alice, block.timestamp);
        assertEq(hook.referrerOf(bob), alice);
        vm.prank(bob);
        router.buy{value: 10 ether}(address(t), 10 ether, 0, carol, block.timestamp); // bob's second wallet
        assertEq(hook.referrerOf(bob), alice);
        assertEq(hook.claimable(alice, NATIVE), 0.1 ether);
        assertEq(hook.claimable(carol, NATIVE), 0);
        // a referrer can't be bound to someone the buyer referred (no A <-> B loop)
        vm.prank(alice);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, bob, block.timestamp);
        assertEq(hook.referrerOf(alice), address(0));
        // the buyer itself is never a referrer
        vm.prank(carol);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, carol, block.timestamp);
        assertEq(hook.referrerOf(carol), address(0));
    }

    // L-3: the MEV shield cap can't be set below 5 gwei of priority, nor last past MAX_MEV_BLOCKS.
    function test_L3_mevShieldBounds() public {
        AvaxHook.HookConfig memory c;
        c.mevBlocks = 300;
        c.maxPriorityFee = 2 gwei;
        vm.expectRevert(AvaxHook.BadConfig.selector);
        hook.validateConfig(c);
        c.maxPriorityFee = 5 gwei;
        hook.validateConfig(c);
        c.mevBlocks = hook.MAX_MEV_BLOCKS() + 1;
        vm.expectRevert(AvaxHook.BadConfig.selector);
        hook.validateConfig(c);
    }

    // I-1: a last-buyer pot filled only by non-router buys has no leader; it goes to the creator
    // after TIMER_ORPHAN_SECONDS instead of sitting stuck.
    function test_I1_orphanTimerPotGoesToCreator() public {
        AvaxHook.HookConfig memory c;
        c.timerPotBps = 200;
        c.timerSeconds = 600;
        c.timerMinBuy = 0.5 ether;
        (HookToken t, PoolKey memory key) = _grad(c);
        FixSwapper j = new FixSwapper(PM);
        vm.deal(address(j), 100 ether);
        j.swap(key, Currency.unwrap(key.currency1) == address(t), -int256(10 ether));
        PoolId id = key.toId();
        uint256 pot = hook.poolState(id).timerPotWei;
        assertEq(pot, 0.2 ether);
        vm.warp(block.timestamp + 1 days);
        hook.settleTimerPot(id);
        assertEq(hook.claimable(creator, NATIVE), 0); // too early
        vm.warp(block.timestamp + hook.TIMER_ORPHAN_SECONDS());
        hook.settleTimerPot(id);
        assertEq(hook.claimable(creator, NATIVE), pot);
        assertEq(hook.poolState(id).timerPotWei, 0);
    }
}
