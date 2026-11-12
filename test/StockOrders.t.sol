// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";
import {StockGateway} from "../contracts/bridge/StockGateway.sol";
import {BridgedStock} from "../contracts/bridge/BridgedStock.sol";
import {StockOrders} from "../contracts/stock/StockOrders.sol";

contract MockUsd is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Takes 1% on every transfer.
contract FotUsd is ERC20 {
    constructor() ERC20("Taxed USD", "TUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0xdead), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// Rejects native AVAX, to check that a failed payout reverts the whole fill.
contract NoAvax {}

/// Fork-free: a fresh Uniswap v4 PoolManager, launchpad, router, bridge gateway and registry on the
/// test chain. mStock is minted by pranking the gateway (the bridge itself is covered in StockBridge.t.sol).
contract StockOrdersTest is Test {
    PoolManager pm;
    HookLaunchpad pad;
    AvaxHookRouter router;
    AvaxHook hook;
    QuoteRegistry registry;
    StockGateway gateway;
    BridgedStock mNVDA;
    MockUsd usdc;
    StockOrders orders;

    address constant NVDA_RH = address(0x4E5DA);
    address owner = makeAddr("owner");
    address solver = makeAddr("solver");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address treasury = makeAddr("feeTreasury");

    // prices: AVAX $25, USDC $1, mNVDA $200
    uint256 constant AVAX_USD = 25e8;
    uint256 constant NVDA_USD = 200e8;

    function setUp() public {
        vm.warp(1_750_000_000);
        pm = new PoolManager(address(this));
        (, bytes32 salt) =
            HookMiner.find(address(this), uint160(_flags()), type(AvaxHook).creationCode, abi.encode(address(pm), address(this)));
        hook = new AvaxHook{salt: salt}(IPoolManager(address(pm)), address(this));
        HookTokenFactory factory = new HookTokenFactory();
        registry = new QuoteRegistry(address(this));
        pad = new HookLaunchpad(IPoolManager(address(pm)), hook, factory, registry, address(this), makeAddr("treasury"));
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        router = new AvaxHookRouter(IPoolManager(address(pm)), pad);
        hook.bindRouter(address(router));

        gateway = new StockGateway(address(this), 4663);
        mNVDA = gateway.createStock(NVDA_RH, "NVIDIA (AvaxHook bridged)", "mNVDA");
        usdc = new MockUsd();

        registry.setQuote(address(0), true, address(new ManualPriceFeed(address(this), "AVAX / USD", 8, int256(AVAX_USD))));
        registry.setQuote(address(usdc), true, address(new ManualPriceFeed(address(this), "USDC / USD", 8, 1e8)));
        registry.setQuote(address(mNVDA), true, address(new ManualPriceFeed(address(this), "mNVDA / USD", 8, int256(NVDA_USD))));

        orders = new StockOrders(pad, router, registry, gateway, owner, treasury);
        pad.setTrustedCaller(address(orders), true); // delivers curve buys to recipients, sells deposits
        vm.prank(owner);
        orders.setSolver(solver, true);

        // balances
        _mintStock(solver, 1_000 ether);
        _mintStock(alice, 100 ether);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(solver, 1_000_000e6);
        vm.deal(alice, 1_000 ether);
        vm.deal(solver, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(orders), type(uint256).max);
        vm.prank(alice);
        mNVDA.approve(address(orders), type(uint256).max);
        vm.prank(solver);
        mNVDA.approve(address(orders), type(uint256).max);
        vm.prank(solver);
        usdc.approve(address(orders), type(uint256).max);
    }

    function _flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _mintStock(address to, uint256 amount) internal {
        vm.prank(address(gateway));
        mNVDA.mint(to, amount);
    }

    function _launch() internal returns (address t) {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Green Team";
        a.symbol = "GPU";
        a.quote = address(mNVDA);
        a.hook.baseFeePips = 3_000;
        a.hook.maxFeePips = 3_000;
        a.hook.burnBps = 100;
        uint256 fee = pad.creationFee();
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        t = pad.launch{value: fee}(a);
    }

    function _graduated() internal returns (address t) {
        t = _launch();
        _mintStock(carol, 100 ether);
        vm.startPrank(carol);
        mNVDA.approve(address(pad), type(uint256).max);
        pad.buyWithQuote(t, 60 ether, 0); // ~38 mNVDA completes the curve
        vm.stopPrank();
        assertTrue(pad.getLaunch(t).graduated);
    }

    function _dl() internal view returns (uint64) {
        return uint64(block.timestamp + 1 hours);
    }

    // ---------------------------------------------------------------- BuyStock

    function test_buyStock_usdc_fill() public {
        uint256 q = orders.quote(address(usdc), 2_000e6, address(mNVDA));
        assertEq(q, 9.92015 ether); // ($2,000 - 0.3% fee) / $200 minus 0.5% spread

        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 2_000e6, address(mNVDA), address(0), 9.9 ether, _dl(), bob);
        assertEq(id, 1);
        assertEq(orders.orderCount(), 1);
        assertEq(usdc.balanceOf(address(orders)), 2_000e6);
        StockOrders.Order memory o = orders.getOrder(id);
        assertEq(o.owner, alice);
        assertEq(o.recipient, bob);
        assertEq(uint8(o.kind), uint8(StockOrders.Kind.BuyStock));
        assertEq(uint8(o.status), uint8(StockOrders.Status.Open));

        // below minOut
        vm.prank(solver);
        vm.expectRevert(StockOrders.Slippage.selector);
        orders.fill(id, 9.8 ether);

        uint256 solverUsdc = usdc.balanceOf(solver);
        vm.prank(solver);
        orders.fill(id, uint128(q));
        assertEq(mNVDA.balanceOf(bob), q);
        assertEq(usdc.balanceOf(solver) - solverUsdc, 1_994e6); // payment minus the 0.3% fee
        assertEq(usdc.balanceOf(treasury), 6e6);
        assertEq(usdc.balanceOf(address(orders)), 0);
        o = orders.getOrder(id);
        assertEq(uint8(o.status), uint8(StockOrders.Status.Filled));
        assertEq(o.stockAmount, q);
        assertEq(o.amountOut, q);

        vm.prank(solver);
        vm.expectRevert(StockOrders.NotOpen.selector);
        orders.fill(id, uint128(q));
    }

    function test_buyStock_native_fill() public {
        uint256 q = orders.quote(address(0), 80 ether, address(mNVDA)); // $2,000
        assertEq(q, 9.92015 ether);

        vm.prank(alice);
        vm.expectRevert(StockOrders.BadValue.selector);
        orders.openBuy{value: 79 ether}(address(0), 80 ether, address(mNVDA), address(0), 9 ether, _dl(), address(0));

        vm.prank(alice);
        uint256 id = orders.openBuy{value: 80 ether}(address(0), 80 ether, address(mNVDA), address(0), 9 ether, _dl(), address(0));
        assertEq(orders.getOrder(id).recipient, alice); // defaults to owner
        assertEq(address(orders).balance, 80 ether);

        uint256 before = solver.balance;
        uint256 stockBefore = mNVDA.balanceOf(alice);
        vm.prank(solver);
        orders.fill(id, uint128(q));
        assertEq(solver.balance - before, 79.76 ether);
        assertEq(treasury.balance, 0.24 ether);
        assertEq(mNVDA.balanceOf(alice) - stockBefore, q);
        assertEq(address(orders).balance, 0);
    }

    function test_open_erc20_withValue_reverts() public {
        vm.prank(alice);
        vm.expectRevert(StockOrders.BadValue.selector);
        orders.openBuy{value: 1}(address(usdc), 100e6, address(mNVDA), address(0), 1, _dl(), alice);
    }

    function test_fill_nativePayout_toRejectingSolver_reverts() public {
        NoAvax s = new NoAvax();
        vm.prank(owner);
        orders.setSolver(address(s), true);
        _mintStock(address(s), 10 ether);
        vm.prank(address(s));
        mNVDA.approve(address(orders), type(uint256).max);

        vm.prank(alice);
        uint256 id = orders.openBuy{value: 80 ether}(address(0), 80 ether, address(mNVDA), address(0), 9 ether, _dl(), alice);
        vm.prank(address(s));
        vm.expectRevert(StockOrders.TransferFailed.selector);
        orders.fill(id, 9.5 ether);
        assertEq(uint8(orders.getOrder(id).status), uint8(StockOrders.Status.Open));
    }

    // ---------------------------------------------------------------- BuyLaunch

    function test_buyLaunch_preGraduation_deliversToRecipient() public {
        address t = _launch();
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 1_000e6, address(mNVDA), t, 1, _dl(), bob);
        assertEq(uint8(orders.getOrder(id).kind), uint8(StockOrders.Kind.BuyLaunch));

        // a minOut the curve can't meet reverts the whole fill
        vm.prank(alice);
        uint256 id2 = orders.openBuy(address(usdc), 1_000e6, address(mNVDA), t, type(uint128).max, _dl(), bob);
        vm.prank(solver);
        vm.expectRevert(HookLaunchpad.Slippage.selector);
        orders.fill(id2, 4.9 ether);

        uint256 solverStock = mNVDA.balanceOf(solver);
        vm.prank(solver);
        orders.fill(id, 4.9 ether);
        uint256 got = HookToken(t).balanceOf(bob);
        assertGt(got, 0);
        assertFalse(pad.getLaunch(t).graduated);
        assertEq(solverStock - mNVDA.balanceOf(solver), 4.9 ether);
        assertEq(mNVDA.balanceOf(address(orders)), 0);
        assertEq(mNVDA.balanceOf(bob), 0); // all of it went into the curve
        assertEq(usdc.balanceOf(solver), 1_000_000e6 + 997e6);
        assertEq(usdc.balanceOf(treasury), 3e6);
        StockOrders.Order memory o = orders.getOrder(id);
        assertEq(o.amountOut, got);
        assertEq(o.stockAmount, 4.9 ether);
        assertEq(HookToken(t).balanceOf(address(orders)), 0);
    }

    function test_buyLaunch_contractRecipient_reverts() public {
        address t = _launch();
        vm.prank(alice);
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.openBuy(address(usdc), 1_000e6, address(mNVDA), t, 1, _dl(), address(pad));
    }

    function test_buyLaunch_completesCurve_refundsUnusedToRecipient() public {
        address t = _launch();
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 20_000e6, address(mNVDA), t, 1, _dl(), bob);
        vm.prank(solver);
        orders.fill(id, 60 ether); // ~38 needed
        HookLaunchpad.Launch memory l = pad.getLaunch(t);
        assertTrue(l.graduated);
        uint256 refund = mNVDA.balanceOf(bob);
        assertGt(refund, 15 ether);
        assertLt(refund, 25 ether);
        assertEq(mNVDA.balanceOf(address(orders)), 0);
        assertEq(HookToken(t).balanceOf(bob), 800_000_000 ether);
    }

    function test_buyLaunch_graduated_viaRouter() public {
        address t = _graduated();
        vm.prank(alice);
        uint256 id = orders.openBuy{value: 40 ether}(address(0), 40 ether, address(mNVDA), t, 1, _dl(), bob);
        vm.prank(solver);
        orders.fill(id, 4.9 ether);
        uint256 got = HookToken(t).balanceOf(bob);
        assertGt(got, 0);
        assertEq(orders.getOrder(id).amountOut, got);
        assertEq(mNVDA.balanceOf(address(orders)), 0);
        assertEq(HookToken(t).balanceOf(address(orders)), 0);

        vm.prank(alice);
        uint256 id2 = orders.openBuy{value: 40 ether}(address(0), 40 ether, address(mNVDA), t, type(uint128).max, _dl(), bob);
        vm.prank(solver);
        vm.expectRevert(); // router Slippage inside the v4 unlock
        orders.fill(id2, 4.9 ether);
    }

    function test_buyLaunch_wrongQuote_reverts() public {
        // a launch quoted in AVAX can't be bought with mNVDA
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Avax One";
        a.symbol = "A1";
        a.hook.baseFeePips = 3_000;
        a.hook.maxFeePips = 3_000;
        uint256 fee = pad.creationFee();
        vm.prank(carol);
        vm.deal(carol, 1 ether);
        address t = pad.launch{value: fee}(a);
        vm.prank(alice);
        vm.expectRevert(StockOrders.NotAllowed.selector);
        orders.openBuy(address(usdc), 100e6, address(mNVDA), t, 1, _dl(), alice);
    }

    // ---------------------------------------------------------------- SellStock

    function test_sellStock_usdc_fill() public {
        uint256 q = orders.quoteSell(address(mNVDA), 10 ether, address(usdc));
        assertEq(q, 1_984.03e6); // $2,000 minus 0.5% spread minus 0.3% fee

        vm.prank(alice);
        uint256 id = orders.openSell(address(mNVDA), address(0), 10 ether, 0, address(usdc), 1_980e6, _dl(), bob);
        StockOrders.Order memory o = orders.getOrder(id);
        assertEq(uint8(o.kind), uint8(StockOrders.Kind.SellStock));
        assertEq(o.stockAmount, 10 ether);
        assertEq(mNVDA.balanceOf(address(orders)), 10 ether);

        vm.prank(solver);
        vm.expectRevert(StockOrders.Slippage.selector);
        orders.fill(id, 1_979e6);

        uint256 solverStock = mNVDA.balanceOf(solver);
        uint256 solverUsdc = usdc.balanceOf(solver);
        uint256 fee = orders.fillFee(id, uint128(q));
        assertEq(fee, 5.97e6); // 0.3% of the 1,990 USDC the solver delivers
        vm.prank(solver);
        orders.fill(id, uint128(q));
        assertEq(usdc.balanceOf(bob), q);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(solverUsdc - usdc.balanceOf(solver), 1_990e6);
        assertEq(mNVDA.balanceOf(solver) - solverStock, 10 ether);
        assertEq(mNVDA.balanceOf(address(orders)), 0);
        assertEq(orders.getOrder(id).amountOut, q);
    }

    function test_sellStock_native_fill() public {
        vm.prank(alice);
        uint256 id = orders.openSell(address(mNVDA), address(0), 10 ether, 0, address(0), 79 ether, _dl(), bob);
        uint256 q = orders.quoteSell(address(mNVDA), 10 ether, address(0));
        assertEq(q, 79.3612 ether);
        uint256 fee = orders.fillFee(id, uint128(q));
        assertEq(q + fee, 79.6 ether);

        vm.prank(solver);
        vm.expectRevert(StockOrders.BadValue.selector);
        orders.fill{value: q}(id, uint128(q)); // the fee comes on top

        vm.prank(solver);
        orders.fill{value: q + fee}(id, uint128(q));
        assertEq(bob.balance, q);
        assertEq(treasury.balance, fee);
        assertEq(address(orders).balance, 0);
    }

    // ---------------------------------------------------------------- SellLaunch

    function test_sellLaunch_preGraduation_curveSell() public {
        address t = _launch();
        vm.startPrank(alice);
        mNVDA.approve(address(pad), type(uint256).max);
        pad.buyWithQuote(t, 5 ether, 0);
        uint256 bal = HookToken(t).balanceOf(alice);
        HookToken(t).approve(address(orders), bal);

        vm.expectRevert(HookLaunchpad.Slippage.selector);
        orders.openSell(address(mNVDA), t, uint128(bal), 5 ether, address(usdc), 1, _dl(), alice);

        uint256 id = orders.openSell(address(mNVDA), t, uint128(bal), 4.9 ether, address(usdc), 900e6, _dl(), alice);
        vm.stopPrank();

        StockOrders.Order memory o = orders.getOrder(id);
        assertEq(uint8(o.kind), uint8(StockOrders.Kind.SellLaunch));
        assertEq(o.amountIn, bal);
        assertGt(o.stockAmount, 4.9 ether);
        assertEq(mNVDA.balanceOf(address(orders)), o.stockAmount);
        assertEq(HookToken(t).balanceOf(alice), 0);
        assertEq(HookToken(t).balanceOf(address(orders)), 0);

        uint256 pay = orders.quoteSell(address(mNVDA), o.stockAmount, address(usdc));
        uint256 before = usdc.balanceOf(alice);
        vm.prank(solver);
        orders.fill(id, uint128(pay));
        assertEq(usdc.balanceOf(alice) - before, pay);
        assertEq(usdc.balanceOf(treasury), orders.fillFee(id, uint128(pay)));
        assertGt(usdc.balanceOf(treasury), 0);
        assertEq(mNVDA.balanceOf(address(orders)), 0);
    }

    function test_sellLaunch_graduated_viaRouter() public {
        address t = _graduated();
        vm.startPrank(alice);
        mNVDA.approve(address(router), type(uint256).max);
        uint256 got = router.buy(t, 2 ether, 0, address(0), block.timestamp);
        HookToken(t).approve(address(orders), got);
        uint256 id = orders.openSell(address(mNVDA), t, uint128(got), 1.9 ether, address(0), 1, _dl(), alice);
        vm.stopPrank();
        StockOrders.Order memory o = orders.getOrder(id);
        assertGt(o.stockAmount, 1.9 ether);
        assertEq(mNVDA.balanceOf(address(orders)), o.stockAmount);

        vm.warp(o.deadline + 1);
        uint256 before = mNVDA.balanceOf(alice);
        orders.cancel(id);
        assertEq(mNVDA.balanceOf(alice) - before, o.stockAmount);
    }

    function test_launchpad_sellDeposited_needsDeposit() public {
        address t = _launch();
        vm.startPrank(alice);
        mNVDA.approve(address(pad), type(uint256).max);
        pad.buyWithQuote(t, 5 ether, 0);
        vm.expectRevert(HookLaunchpad.NotTrusted.selector); // untrusted callers can't sell deposits
        pad.sellDeposited(t, 1 ether, 0);
        vm.stopPrank();
        pad.setTrustedCaller(alice, true);
        vm.prank(alice);
        vm.expectRevert(HookLaunchpad.BadArgs.selector); // nothing deposited
        pad.sellDeposited(t, 1 ether, 0);
    }

    function test_launchpad_buyWithQuoteFor() public {
        address t = _launch();
        vm.startPrank(alice);
        mNVDA.approve(address(pad), type(uint256).max);
        vm.expectRevert(HookLaunchpad.NotTrusted.selector); // buying for others is for trusted callers
        pad.buyWithQuoteFor(t, 1 ether, 1, bob);
        vm.stopPrank();
        pad.setTrustedCaller(alice, true);
        vm.prank(alice);
        pad.buyWithQuoteFor(t, 1 ether, 1, bob);
        assertGt(HookToken(t).balanceOf(bob), 0);
        assertEq(HookToken(t).balanceOf(alice), 0);
        assertEq(mNVDA.balanceOf(alice), 99 ether);
    }

    // ---------------------------------------------------------------- cancel / deadline / auth

    function test_cancel_buy_refundsOwner() public {
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 500e6, address(mNVDA), address(0), 1 ether, _dl(), bob);
        vm.prank(alice);
        uint256 idN = orders.openBuy{value: 3 ether}(address(0), 3 ether, address(mNVDA), address(0), 0.1 ether, _dl(), bob);

        vm.expectRevert(StockOrders.NotExpired.selector);
        orders.cancel(id);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(solver);
        vm.expectRevert(StockOrders.Expired.selector);
        orders.fill(id, 3 ether);

        uint256 u = usdc.balanceOf(alice);
        uint256 a = alice.balance;
        vm.prank(carol); // anyone
        orders.cancel(id);
        orders.cancel(idN);
        assertEq(usdc.balanceOf(alice) - u, 500e6);
        assertEq(alice.balance - a, 3 ether);
        assertEq(uint8(orders.getOrder(id).status), uint8(StockOrders.Status.Cancelled));

        vm.expectRevert(StockOrders.NotOpen.selector);
        orders.cancel(id);
    }

    function test_cancel_native_toRejectingOwner_defersRefund() public {
        NoAvax w = new NoAvax(); // e.g. a contract wallet without receive()
        vm.deal(address(w), 5 ether);
        vm.prank(address(w));
        uint256 id = orders.openBuy{value: 3 ether}(address(0), 3 ether, address(mNVDA), address(0), 0.1 ether, _dl(), bob);
        vm.warp(block.timestamp + 1 hours + 1);

        // anyone can still cancel: the refund is credited instead of reverting forever
        vm.prank(carol);
        vm.expectEmit(true, true, false, true, address(orders));
        emit StockOrders.RefundDeferred(id, address(w), address(0), 3 ether);
        orders.cancel(id);
        assertEq(uint8(orders.getOrder(id).status), uint8(StockOrders.Status.Cancelled));
        assertEq(orders.pendingRefunds(address(w), address(0)), 3 ether);
        assertEq(address(orders).balance, 3 ether);

        // nobody else can take it; the owner pulls it to an address that accepts AVAX
        vm.prank(carol);
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.claimRefund(address(0), carol);
        vm.prank(address(w));
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.claimRefund(address(0), address(0));
        vm.prank(address(w));
        vm.expectRevert(StockOrders.TransferFailed.selector); // claiming to itself still fails, balance kept
        orders.claimRefund(address(0), address(w));
        assertEq(orders.pendingRefunds(address(w), address(0)), 3 ether);

        uint256 before = bob.balance;
        vm.prank(address(w));
        orders.claimRefund(address(0), bob);
        assertEq(bob.balance - before, 3 ether);
        assertEq(orders.pendingRefunds(address(w), address(0)), 0);
        assertEq(address(orders).balance, 0);
        vm.prank(address(w));
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.claimRefund(address(0), bob);
    }

    function test_cancel_native_toAcceptingOwner_paysDirectly() public {
        vm.prank(alice);
        uint256 id = orders.openBuy{value: 2 ether}(address(0), 2 ether, address(mNVDA), address(0), 0.1 ether, _dl(), bob);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 a = alice.balance;
        orders.cancel(id);
        assertEq(alice.balance - a, 2 ether);
        assertEq(orders.pendingRefunds(alice, address(0)), 0);
    }

    function test_cancel_sellStock_refundsStock() public {
        vm.prank(alice);
        uint256 id = orders.openSell(address(mNVDA), address(0), 7 ether, 0, address(usdc), 1, _dl(), bob);
        assertEq(mNVDA.balanceOf(alice), 93 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        orders.cancel(id);
        assertEq(mNVDA.balanceOf(alice), 100 ether);
        assertEq(mNVDA.balanceOf(bob), 0);
    }

    function test_deadlineBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(StockOrders.BadDeadline.selector);
        orders.openBuy(address(usdc), 1e6, address(mNVDA), address(0), 1, uint64(block.timestamp + 2 minutes - 1), alice);
        vm.expectRevert(StockOrders.BadDeadline.selector);
        orders.openBuy(address(usdc), 1e6, address(mNVDA), address(0), 1, uint64(block.timestamp + 2 hours + 1), alice);
        vm.expectRevert(StockOrders.BadDeadline.selector);
        orders.openSell(address(mNVDA), address(0), 1 ether, 0, address(usdc), 1, uint64(block.timestamp), alice);
        orders.openBuy(address(usdc), 1e6, address(mNVDA), address(0), 1, uint64(block.timestamp + 2 minutes), alice);
        orders.openBuy(address(usdc), 1e6, address(mNVDA), address(0), 1, uint64(block.timestamp + 2 hours), alice);
        vm.stopPrank();
        assertEq(orders.orderCount(), 2);
    }

    function test_onlySolver_and_owner() public {
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 1e6, address(mNVDA), address(0), 1, _dl(), alice);
        vm.prank(alice);
        vm.expectRevert(StockOrders.NotSolver.selector);
        orders.fill(id, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        orders.setSolver(alice, true);

        vm.prank(owner);
        orders.setSolver(solver, false);
        assertFalse(orders.isSolver(solver));
        vm.prank(solver);
        vm.expectRevert(StockOrders.NotSolver.selector);
        orders.fill(id, 1 ether);
    }

    function test_rejectsUnknownTokens() public {
        MockUsd junk = new MockUsd();
        vm.startPrank(alice);
        // pay token not in the registry
        vm.expectRevert(StockOrders.NotAllowed.selector);
        orders.openBuy(address(junk), 1e6, address(mNVDA), address(0), 1, _dl(), alice);
        vm.stopPrank();

        // allowed in the registry but not a gateway-bridged stock
        registry.setQuote(address(junk), true, address(new ManualPriceFeed(address(this), "J", 8, 1e8)));
        vm.prank(alice);
        vm.expectRevert(StockOrders.NotAllowed.selector);
        orders.openBuy(address(usdc), 1e6, address(junk), address(0), 1, _dl(), alice);

        // a bridged stock that the registry hasn't allowed
        BridgedStock mTSLA = gateway.createStock(address(0x7E5A), "Tesla (AvaxHook bridged)", "mTSLA");
        vm.prank(alice);
        vm.expectRevert(StockOrders.NotAllowed.selector);
        orders.openBuy(address(usdc), 1e6, address(mTSLA), address(0), 1, _dl(), alice);

        // zero amounts / minOut, pay == stock
        vm.startPrank(alice);
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.openBuy(address(usdc), 0, address(mNVDA), address(0), 1, _dl(), alice);
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.openBuy(address(usdc), 1e6, address(mNVDA), address(0), 0, _dl(), alice);
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.openSell(address(mNVDA), address(0), 1 ether, 0, address(mNVDA), 1, _dl(), alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- protocol fee

    function test_fee_defaults_and_auth() public {
        assertEq(orders.feeBps(), 30);
        assertEq(orders.MAX_FEE_BPS(), 100);
        assertEq(orders.feeRecipient(), treasury);

        vm.expectRevert(StockOrders.BadArgs.selector);
        new StockOrders(pad, router, registry, gateway, owner, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        orders.setFee(10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        orders.setFeeRecipient(alice);

        vm.startPrank(owner);
        vm.expectRevert(StockOrders.FeeTooHigh.selector);
        orders.setFee(101);
        vm.expectEmit(address(orders));
        emit StockOrders.FeeSet(100);
        orders.setFee(100); // the cap itself is allowed
        assertEq(orders.feeBps(), 100);
        vm.expectRevert(StockOrders.BadArgs.selector);
        orders.setFeeRecipient(address(0));
        orders.setFeeRecipient(carol);
        vm.stopPrank();
        assertEq(orders.feeRecipient(), carol);
    }

    function test_fee_buy_math_fuzz(uint128 amountIn, uint16 bps) public {
        bps = uint16(bound(bps, 0, 100));
        amountIn = uint128(bound(amountIn, 1, 1_000_000e6));
        vm.prank(owner);
        orders.setFee(bps);
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), amountIn, address(mNVDA), address(0), 1, _dl(), alice);
        uint256 fee = orders.fillFee(id, 1 ether);
        assertEq(fee, (uint256(amountIn) * bps) / 10_000);
        uint256 s0 = usdc.balanceOf(solver);
        vm.prank(solver);
        vm.expectEmit(true, true, false, true, address(orders));
        emit StockOrders.OrderFilled(id, solver, 1 ether, 1 ether, fee);
        orders.fill(id, 1 ether);
        assertEq(usdc.balanceOf(solver) - s0 + usdc.balanceOf(treasury), amountIn); // nothing stuck
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(address(orders)), 0);
    }

    function test_fee_sell_math_fuzz(uint128 net, uint16 bps) public {
        bps = uint16(bound(bps, 0, 100));
        net = uint128(bound(net, 1, 100_000e6));
        vm.prank(owner);
        orders.setFee(bps);
        vm.prank(alice);
        uint256 id = orders.openSell(address(mNVDA), address(0), 1 ether, 0, address(usdc), net, _dl(), bob);
        uint256 fee = orders.fillFee(id, net);
        // the fee is bps of the gross the solver delivers (rounded down)
        assertLe(fee * 10_000, (uint256(net) + fee) * bps);
        assertGt((fee + 1) * 10_000, (uint256(net) + fee) * bps);
        uint256 s0 = usdc.balanceOf(solver);
        vm.prank(solver);
        vm.expectRevert(StockOrders.Slippage.selector);
        orders.fill(id, net - 1); // minOut is the net the recipient receives
        vm.prank(solver);
        orders.fill(id, net);
        assertEq(usdc.balanceOf(bob), net);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(s0 - usdc.balanceOf(solver), uint256(net) + fee);
        assertEq(usdc.balanceOf(address(orders)), 0);
    }

    function test_fee_zero_and_cap() public {
        vm.prank(owner);
        orders.setFee(0);
        assertEq(orders.quote(address(usdc), 2_000e6, address(mNVDA)), 9.95 ether);
        vm.prank(alice);
        uint256 id = orders.openBuy(address(usdc), 2_000e6, address(mNVDA), address(0), 1, _dl(), alice);
        vm.prank(solver);
        orders.fill(id, 9 ether);
        assertEq(usdc.balanceOf(treasury), 0);

        vm.prank(owner);
        orders.setFee(100);
        assertEq(orders.quote(address(usdc), 2_000e6, address(mNVDA)), 9.8505 ether); // 1,980 / 200 * 0.995
        vm.prank(alice);
        id = orders.openBuy{value: 10 ether}(address(0), 10 ether, address(mNVDA), address(0), 1, _dl(), alice);
        vm.prank(solver);
        orders.fill(id, 1 ether);
        assertEq(treasury.balance, 0.1 ether);
    }

    function test_fee_changeAfterOpen_neverTouchesUser() public {
        vm.prank(alice);
        uint256 id = orders.openSell(address(mNVDA), address(0), 10 ether, 0, address(usdc), 1_980e6, _dl(), bob);
        vm.prank(owner);
        orders.setFee(100);
        uint256 fee = orders.fillFee(id, 1_980e6);
        assertEq(fee, 20e6); // 1% of the 2,000 gross
        vm.prank(solver);
        orders.fill(id, 1_980e6);
        assertEq(usdc.balanceOf(bob), 1_980e6);
        assertEq(usdc.balanceOf(treasury), 20e6);
    }

    function test_fee_notChargedOnCancel() public {
        vm.prank(alice);
        uint256 a = orders.openBuy(address(usdc), 1_000e6, address(mNVDA), address(0), 1, _dl(), alice);
        vm.prank(alice);
        uint256 b = orders.openBuy{value: 5 ether}(address(0), 5 ether, address(mNVDA), address(0), 1, _dl(), alice);
        vm.prank(alice);
        uint256 c = orders.openSell(address(mNVDA), address(0), 3 ether, 0, address(usdc), 1, _dl(), alice);
        uint256 u = usdc.balanceOf(alice);
        uint256 n = alice.balance;
        uint256 m = mNVDA.balanceOf(alice);
        vm.warp(block.timestamp + 1 hours + 1);
        orders.cancel(a);
        orders.cancel(b);
        orders.cancel(c);
        assertEq(usdc.balanceOf(alice) - u, 1_000e6);
        assertEq(alice.balance - n, 5 ether);
        assertEq(mNVDA.balanceOf(alice) - m, 3 ether);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(treasury.balance, 0);
    }

    function test_fee_nativeToRejectingRecipient_revertsFill() public {
        NoAvax t = new NoAvax();
        vm.prank(owner);
        orders.setFeeRecipient(address(t));
        vm.prank(alice);
        uint256 id = orders.openBuy{value: 10 ether}(address(0), 10 ether, address(mNVDA), address(0), 1, _dl(), alice);
        vm.prank(solver);
        vm.expectRevert(StockOrders.TransferFailed.selector);
        orders.fill(id, 1 ether);
        assertEq(uint8(orders.getOrder(id).status), uint8(StockOrders.Status.Open));
    }

    function test_fee_feeOnTransferPayToken_rejected() public {
        FotUsd t = new FotUsd();
        registry.setQuote(address(t), true, address(new ManualPriceFeed(address(this), "TUSD", 8, 1e8)));
        t.mint(alice, 1_000e18);
        t.mint(solver, 1_000e18);
        vm.prank(alice);
        t.approve(address(orders), type(uint256).max);
        vm.prank(solver);
        t.approve(address(orders), type(uint256).max);
        // buys: the payment is pulled exactly at open
        vm.prank(alice);
        vm.expectRevert(StockOrders.TransferFailed.selector);
        orders.openBuy(address(t), 100e18, address(mNVDA), address(0), 1, _dl(), alice);
        // sells: the solver's payout + fee is pulled exactly at fill
        vm.prank(alice);
        uint256 id = orders.openSell(address(mNVDA), address(0), 1 ether, 0, address(t), 1, _dl(), alice);
        vm.prank(solver);
        vm.expectRevert(StockOrders.TransferFailed.selector);
        orders.fill(id, 100e18);
    }
}
