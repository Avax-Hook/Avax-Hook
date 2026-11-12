// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {HookLens} from "../contracts/HookLens.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Fork test against the live Uniswap v4 PoolManager on Avalanche C-Chain.
contract AvaxHookTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    AvaxHook hook;
    HookLaunchpad pad;
    AvaxHookRouter router;
    HookLens lens;
    QuoteRegistry registry;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    Currency constant NATIVE = Currency.wrap(address(0));
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), uint160(_flags()), type(AvaxHook).creationCode, abi.encode(address(PM), address(this))
        );
        hook = new AvaxHook{salt: salt}(PM, address(this));
        assertEq(address(hook), hookAddr);

        HookTokenFactory factory = new HookTokenFactory();
        registry = new QuoteRegistry(address(this));
        registry.setQuote(address(0), true, 0x0A77230d17318075983913bC2145DB16C7366156); // Chainlink AVAX/USD
        registry.setFdv(250e8, 5_000e8); // 10x smaller than production so tests fill curves quickly
        pad = new HookLaunchpad(PM, hook, factory, registry, address(this), treasury);
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        router = new AvaxHookRouter(PM, pad);
        hook.bindRouter(address(router));
        lens = new HookLens(pad);

        vm.deal(creator, 1_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    function _flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _cfg() internal pure returns (AvaxHook.HookConfig memory c) {
        c.guardBlocks = 20;
        c.maxBuyPerBlock = 5 ether;
        c.snipeTaxBps = 1_000;
        c.baseFeePips = 3_000;
        c.maxFeePips = 10_000;
        c.surgeSens = 2;
        c.burnBps = 200;
        c.lpBps = 50;
        c.potBps = 100;
        c.potEveryNBuys = 3;
        c.potMinBuy = 0.1 ether;
    }

    function _launch(uint256 devBuy) internal returns (HookToken t) {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Gone Fishin";
        a.symbol = "FISH";
        a.meta = HookToken.Metadata("a red fish", "https://example.com/fish.png", "", "", "");
        a.hook = _cfg();
        a.devBuy = devBuy;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookToken(pad.launch{value: fee + devBuy}(a));
    }

    function test_launchAndCurveTrade() public {
        HookToken t = _launch(1 ether);
        uint256 creatorBal = t.balanceOf(creator);
        assertGt(creatorBal, 0);

        // curve-phase anti-snipe: per-block cap
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 6 ether}(address(t), 0);

        vm.roll(block.number + 25);
        (uint256 q,) = lens.quoteBuy(address(t), 2 ether);
        vm.prank(alice);
        pad.buy{value: 2 ether}(address(t), q);
        assertEq(t.balanceOf(alice), q);

        // tokens can't move before graduation
        vm.prank(alice);
        vm.expectRevert(HookToken.CurvePhaseTransfer.selector);
        t.transfer(bob, 1);

        uint256 sellQ = lens.quoteSell(address(t), q);
        uint256 before = alice.balance;
        vm.prank(alice);
        pad.sell(address(t), q, sellQ);
        assertEq(alice.balance - before, sellQ);
        assertEq(t.balanceOf(alice), 0);
        assertLt(sellQ, 2 ether); // round trip pays fees both ways
        assertGt(sellQ, 1.98 ether); // only the fixed 0.3% each way
    }

    function test_graduationIntoUniswapV4() public {
        HookToken t = _launch(0);
        vm.roll(block.number + 25);

        vm.prank(alice);
        pad.buy{value: 200 ether}(address(t), 0); // overshoots the target, refunded

        HookLaunchpad.Launch memory l = pad.getLaunch(address(t));
        assertTrue(l.complete);
        assertTrue(l.graduated);
        assertTrue(t.tradingOpen());
        assertEq(t.balanceOf(address(pad)), 0);
        assertGt(alice.balance, 1_000 ether - 100 ether); // only the ~81 AVAX the curve needed was kept

        PoolId id = pad.poolId(address(t));
        (uint160 sqrtP,,,) = PM.getSlot0(id);
        assertGt(sqrtP, 0);
        assertGt(PM.getLiquidity(id), 0);

        // guard active at pool open: per-block cap + exact output blocked
        vm.prank(bob);
        vm.expectRevert();
        router.buy{value: 6 ether}(address(t), 6 ether, 0, address(0), block.timestamp);

        vm.prank(bob);
        uint256 out = router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp);
        assertGt(out, 0);
        assertGt(t.balanceOf(DEAD), 0); // auto burn

        // after the guard: pot fills and the 3rd qualifying buy wins it
        uint256 b = block.number + 30;
        for (uint256 i; i < 3; ++i) {
            vm.roll(b + i);
            vm.prank(bob);
            router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp);
        }
        assertGt(hook.claimable(bob, NATIVE), 0);
        uint256 pot = hook.claimable(bob, NATIVE);
        uint256 balBefore = bob.balance;
        vm.prank(bob);
        hook.claim(NATIVE, bob);
        assertEq(bob.balance - balBefore, pot);

        // sell back through the router
        uint256 bobTokens = t.balanceOf(bob);
        vm.startPrank(bob);
        t.approve(address(router), bobTokens);
        uint256 avaxOut = router.sell(address(t), bobTokens / 2, 0, block.timestamp);
        vm.stopPrank();
        assertGt(avaxOut, 0);

        // locked LP fees: AVAX split creator/protocol, token side burned
        uint256 creatorBefore = pad.claimable(creator, address(0));
        pad.collectLpFees(address(t));
        assertGt(pad.claimable(creator, address(0)), creatorBefore); // LP fees: all to the creator

        vm.prank(creator);
        pad.claim(address(0));
    }


    // ------------------------------------------------------------------ new hooks

    function _plain() internal pure returns (AvaxHook.HookConfig memory c) {
        c.baseFeePips = 3_000;
        c.maxFeePips = 3_000;
    }

    function _graduate(AvaxHook.HookConfig memory c) internal returns (HookToken t) {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Hooked";
        a.symbol = "HKD";
        a.hook = c;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookToken(pad.launch{value: fee}(a));
        vm.prank(alice);
        pad.buy{value: 200 ether}(address(t), 0);
        assertTrue(pad.getLaunch(address(t)).graduated);
    }

    function _buy(address who, HookToken t, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return router.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp);
    }

    function _sell(address who, HookToken t, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(who);
        t.approve(address(router), amt);
        out = router.sell(address(t), amt, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_whaleGuard() public {
        AvaxHook.HookConfig memory c = _plain();
        c.whaleBlocks = 50;
        c.maxBuyPerTx = 2 ether;
        HookToken t = _graduate(c);
        vm.prank(bob);
        vm.expectRevert();
        router.buy{value: 3 ether}(address(t), 3 ether, 0, address(0), block.timestamp);
        _buy(bob, t, 2 ether);
        vm.roll(block.number + 51);
        _buy(bob, t, 10 ether); // window over
    }

    function test_dumpGuard() public {
        AvaxHook.HookConfig memory c = _plain();
        c.dumpBlocks = 50;
        c.maxSellBps = 10; // 0.1% of supply = 1M tokens per sell
        HookToken t = _graduate(c);
        _buy(bob, t, 5 ether);
        vm.startPrank(bob);
        t.approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.sell(address(t), 2_000_000 ether, 0, block.timestamp);
        router.sell(address(t), 1_000_000 ether, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_mevShield() public {
        AvaxHook.HookConfig memory c = _plain();
        c.mevBlocks = 50;
        c.maxPriorityFee = 5 gwei;
        HookToken t = _graduate(c);
        vm.fee(25 gwei);
        vm.txGasPrice(31 gwei); // 6 gwei priority
        vm.prank(bob);
        vm.expectRevert();
        router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp);
        vm.txGasPrice(26 gwei);
        _buy(bob, t, 1 ether);
    }

    function test_sellTaxDecays() public {
        AvaxHook.HookConfig memory c = _plain();
        c.sellTaxBlocks = 100;
        c.sellTaxPips = 100_000; // 10% at open
        HookToken t = _graduate(c);
        PoolId id = pad.poolId(address(t));
        assertEq(hook.currentSellTax(id), 100_000);
        vm.roll(block.number + 50);
        assertEq(hook.currentSellTax(id), 50_000);
        vm.roll(block.number + 60);
        assertEq(hook.currentSellTax(id), 0);
    }

    function test_creatorFeeAndReferral() public {
        AvaxHook.HookConfig memory c = _plain();
        c.creatorFeeBps = 100;
        c.referralBps = 50;
        HookToken t = _graduate(c);
        vm.prank(bob);
        router.buy{value: 10 ether}(address(t), 10 ether, 0, alice, block.timestamp);
        assertEq(hook.claimable(alice, NATIVE), 0.05 ether); // referral comes out of the creator fee
        assertEq(hook.claimable(creator, NATIVE), 0.05 ether);
        uint256 bal = t.balanceOf(bob);
        uint256 out = _sell(bob, t, bal);
        // creator also earns 1% of the sell's AVAX output (before the cut)
        assertApproxEqRel(hook.claimable(creator, NATIVE) - 0.05 ether, (out * 100) / 9_870, 0.001e18);
        assertGt(hook.claimable(treasury, NATIVE), 0.03 ether); // fixed 0.3% protocol fee
    }

    function test_buybackAndBurn() public {
        AvaxHook.HookConfig memory c = _plain();
        c.buybackBps = 500; // 5% of sells saved
        c.buybackMaxSpend = 1 ether;
        HookToken t = _graduate(c);
        _buy(bob, t, 20 ether);
        _sell(bob, t, t.balanceOf(bob));
        PoolId id = pad.poolId(address(t));
        uint256 saved = hook.poolState(id).buybackWei;
        assertGt(saved, 0.1 ether);
        PoolKey memory k0 = pad.poolKey(address(t));
        vm.expectRevert(AvaxHook.BuybackNotReady.selector);
        hook.executeBuyback(k0); // no reference price old enough yet
        vm.roll(block.number + hook.REF_MIN_AGE_BLOCKS());
        uint256 deadBefore = t.balanceOf(DEAD);
        (uint256 spent, uint256 burned) = hook.executeBuyback(pad.poolKey(address(t)));
        assertGt(spent, 0);
        assertLe(spent, 1 ether);
        assertEq(t.balanceOf(DEAD) - deadBefore, burned);
        PoolKey memory key = pad.poolKey(address(t));
        vm.expectRevert(AvaxHook.BuybackNotReady.selector);
        hook.executeBuyback(key); // cooldown
    }

    function test_timerPot() public {
        AvaxHook.HookConfig memory c = _plain();
        c.timerPotBps = 200;
        c.timerSeconds = 600;
        c.timerMinBuy = 0.5 ether;
        HookToken t = _graduate(c);
        _buy(alice, t, 5 ether);
        vm.warp(block.timestamp + 100);
        _buy(bob, t, 5 ether); // bob leads
        vm.warp(block.timestamp + 601);
        hook.settleTimerPot(pad.poolId(address(t)));
        assertEq(hook.claimable(bob, NATIVE), 0.2 ether);
    }

    function test_volatilityFee() public {
        AvaxHook.HookConfig memory c = _plain();
        c.volPipsPerTick = 10;
        c.volMaxPips = 50_000;
        HookToken t = _graduate(c);
        uint256 snap = vm.snapshotState();
        _buy(bob, t, 5 ether);
        uint256 sameBlock = _buy(bob, t, 5 ether); // price already moved this block: extra fee
        vm.revertToState(snap);
        _buy(bob, t, 5 ether);
        vm.roll(block.number + 1);
        uint256 nextBlock = _buy(bob, t, 5 ether); // fresh block: no volatility fee
        assertLt(sameBlock, nextBlock);
    }

    function test_outsiderCannotInitializeHookPool() public {
        HookToken t = _launch(0);
        PoolKey memory key = pad.poolKey(address(t));
        vm.expectRevert();
        PM.initialize(key, 79228162514264337593543950336);
    }

    function test_blueprintRoyalty() public {
        AvaxHook.HookConfig memory bc = _cfg();
        bc.creatorFeeBps = 100; // 1% creator fee; the blueprint author gets 10% of it
        vm.prank(bob);
        uint32 id = pad.saveBlueprint("Fair start", bc, 1_000);
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Blue";
        a.symbol = "BLU";
        a.blueprintId = id;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        address t = pad.launch{value: fee}(a);
        vm.roll(block.number + 25);
        vm.prank(alice);
        pad.buy{value: 1 ether}(t, 0);
        assertEq(pad.claimable(bob, address(0)), (1 ether * 100 / 10_000) * 1_000 / 10_000); // from the creator fee
        assertEq(pad.claimable(treasury, address(0)) - fee, 1 ether * 30 / 10_000); // protocol 0.3% untouched
        assertEq(pad.getBlueprint(id).uses, 1);
    }

    function test_usdcQuotedLaunch() public {
        registry.setQuote(USDC, true, 0xF096872672F44d6EBA71458D74fe67F9a77a23B9); // Chainlink USDC/USD
        deal(USDC, alice, 20_000e6);
        deal(USDC, bob, 20_000e6);

        HookLaunchpad.LaunchArgs memory a;
        a.name = "Dollar Fish";
        a.symbol = "DFISH";
        a.quote = USDC;
        a.hook = _plain();
        a.hook.burnBps = 100;
        a.hook.lpBps = 50;
        a.hook.creatorFeeBps = 50;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        HookToken t = HookToken(pad.launch{value: fee}(a));

        // curve buy with USDC
        vm.startPrank(alice);
        IERC20(USDC).approve(address(pad), type(uint256).max);
        (uint256 q,) = lens.quoteBuy(address(t), 100e6);
        pad.buyWithQuote(address(t), 100e6, q);
        assertEq(t.balanceOf(alice), q);
        // fill the curve: pays only what the rest costs
        uint256 before = IERC20(USDC).balanceOf(alice);
        pad.buyWithQuote(address(t), 10_000e6, 0);
        vm.stopPrank();
        assertTrue(pad.getLaunch(address(t)).graduated);
        assertLt(before - IERC20(USDC).balanceOf(alice), 1_000e6); // ~$894 raise at $250 → $5k

        // pool trades in USDC, cuts paid in USDC
        vm.startPrank(bob);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 out = router.buy(address(t), 500e6, 0, address(0), block.timestamp);
        assertGt(out, 0);
        t.approve(address(router), out);
        uint256 usdcOut = router.sell(address(t), out / 2, 0, block.timestamp);
        vm.stopPrank();
        assertGt(usdcOut, 0);
        assertGt(t.balanceOf(DEAD), 0);
        Currency usdcC = Currency.wrap(USDC);
        assertGt(hook.claimable(creator, usdcC), 0);
        vm.prank(creator);
        hook.claim(usdcC, creator);
        assertGt(IERC20(USDC).balanceOf(creator), 0);

        pad.collectLpFees(address(t));
        assertGt(pad.claimable(creator, USDC), 0);
    }

    function test_baseFeeRange() public {
        AvaxHook.HookConfig memory c = _plain();
        c.baseFeePips = 0;
        c.maxFeePips = 0;
        hook.validateConfig(c); // 0% pool is allowed
        c.baseFeePips = 100_000;
        c.maxFeePips = 100_000;
        hook.validateConfig(c); // 10% is the ceiling
        c.baseFeePips = 100_001;
        c.maxFeePips = 100_001;
        vm.expectRevert(AvaxHook.BadConfig.selector);
        hook.validateConfig(c);
        c = _plain();
        c.creatorFeeBps = 1_001; // creator fee above 10%
        vm.expectRevert(AvaxHook.BadConfig.selector);
        hook.validateConfig(c);
    }

    function test_curveStartsAndGraduatesAtUsdMarketCaps() public {
        registry.setFdv(2_500e8, 50_000e8); // production defaults
        HookToken t = _launch(0);
        uint256 avaxUsd = registry.usdPrice(address(0)) / 1e10; // 18 → 8 decimals
        // start: price of 1e18 tokens (scaled 1e18) * 1B tokens, in USD
        uint256 startUsd = (lens.spotPrice(address(t)) * 1e9 / 1e36) * avaxUsd / 1e8;
        assertApproxEqRel(startUsd, 2_500, 0.02e18);
        vm.roll(block.number + 25);
        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        pad.buy{value: 5_000 ether}(address(t), 0);
        HookLaunchpad.Launch memory l = pad.getLaunch(address(t));
        assertTrue(l.graduated);
        uint256 endUsd = (lens.spotPrice(address(t)) * 1e9 / 1e36) * avaxUsd / 1e8;
        assertApproxEqRel(endUsd, 50_000, 0.02e18);
        // the pool opened at the curve's last price: fewer than 200M tokens went in, the rest burned
        assertGt(t.balanceOf(DEAD), 20_000_000 ether);
    }

    /// A micro-priced Avalanche coin (COQ ≈ $0.00000015) as the quote: curve math and the v4 pool
    /// must hold up at ~1e28 quote units.
    function test_microPricedCoinQuote() public {
        address coq = 0x420FcA0121DC28039145009570975747295f2329;
        registry.setFdv(2_500e8, 50_000e8);
        ManualPriceFeed feed = new ManualPriceFeed(address(this), "COQ / USD", 18, 150_200_000_000); // $1.502e-7
        registry.setQuote(coq, true, address(feed));
        deal(coq, alice, 1e30);

        HookLaunchpad.LaunchArgs memory a;
        a.name = "Coq Fish";
        a.symbol = "CQF";
        a.quote = coq;
        a.hook = _plain();
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        HookToken t = HookToken(pad.launch{value: fee}(a));

        uint256 px = registry.usdPrice(coq); // 18 decimals
        uint256 startUsd = lens.spotPrice(address(t)) * 1e9 / 1e36 * px / 1e18;
        assertApproxEqRel(startUsd, 2_500, 0.02e18);

        vm.startPrank(alice);
        IERC20(coq).approve(address(pad), type(uint256).max);
        pad.buyWithQuote(address(t), 1e29, 0);
        vm.stopPrank();
        assertTrue(pad.getLaunch(address(t)).graduated);
        uint256 endUsd = lens.spotPrice(address(t)) * 1e9 / 1e36 * px / 1e18;
        assertApproxEqRel(endUsd, 50_000, 0.02e18);

        // the pool trades
        vm.startPrank(alice);
        IERC20(coq).approve(address(router), type(uint256).max);
        uint256 out = router.buy(address(t), 1e27, 0, address(0), block.timestamp);
        vm.stopPrank();
        assertGt(out, 0);
    }
}
