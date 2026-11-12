// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";

contract Usd6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// M-1 PoC: inside a PoolManager unlock, sync the curve token, buy on the curve straight into the
/// PoolManager, settle, and mint the credit as freely transferable ERC-6909 claims.
contract ShadowMinter is IUnlockCallback {
    IPoolManager immutable pm;
    HookLaunchpad immutable pad;

    constructor(IPoolManager _pm, HookLaunchpad _pad) {
        pm = _pm;
        pad = _pad;
    }

    receive() external payable {}

    /// mode 0: ERC-20 curve, buyWithQuoteFor(to = PoolManager)
    /// mode 1: native curve, buy to self, then forward to the PoolManager
    function run(uint8 mode, address token, address quote, uint256 amount) external payable {
        pm.unlock(abi.encode(mode, token, quote, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint8 mode, address token, address quote, uint256 amount) = abi.decode(data, (uint8, address, address, uint256));
        pm.sync(Currency.wrap(token));
        if (mode == 0) {
            ERC20(quote).approve(address(pad), amount);
            pad.buyWithQuoteFor(token, amount, 0, address(pm));
        } else {
            pad.buy{value: amount}(token, 0);
            HookToken(token).transfer(address(pm), HookToken(token).balanceOf(address(this)));
        }
        uint256 paid = pm.settle();
        pm.mint(address(this), uint256(uint160(token)), paid);
        return "";
    }
}

/// Fork-free regression tests for the launchpad-core fixes: trusted callers (M-1, L-2) and the
/// on-chain price bounds of ManualPriceFeed / QuoteRegistry (L-1).
contract LaunchpadFixesTest is Test {
    PoolManager pm;
    HookLaunchpad pad;
    AvaxHook hook;
    QuoteRegistry registry;
    Usd6 usdc;
    ManualPriceFeed usdFeed;
    ShadowMinter attacker;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_750_000_000);
        pm = new PoolManager(address(this));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(AvaxHook).creationCode, abi.encode(address(pm), address(this)));
        hook = new AvaxHook{salt: salt}(IPoolManager(address(pm)), address(this));
        HookTokenFactory factory = new HookTokenFactory();
        registry = new QuoteRegistry(address(this));
        pad = new HookLaunchpad(IPoolManager(address(pm)), hook, factory, registry, address(this), makeAddr("treasury"));
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));

        usdc = new Usd6();
        usdFeed = new ManualPriceFeed(address(this), "USDC / USD", 8, 1e8);
        registry.setQuote(address(0), true, address(new ManualPriceFeed(address(this), "AVAX / USD", 8, 25e8)));
        registry.setQuote(address(usdc), true, address(usdFeed));

        attacker = new ShadowMinter(IPoolManager(address(pm)), pad);
        usdc.mint(address(attacker), 1_000e6);
        usdc.mint(alice, 1_000e6);
        vm.deal(address(attacker), 100 ether);
        vm.deal(creator, 10 ether);
    }

    function _launch(address quote) internal returns (address t) {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Shadow";
        a.symbol = "SHD";
        a.quote = quote;
        a.hook.baseFeePips = 3_000;
        a.hook.maxFeePips = 3_000;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = pad.launch{value: fee}(a);
    }

    // ---------------------------------------------------------------- M-1

    /// The bypass itself: with the old permissionless `buyWithQuoteFor`, curve tokens land in the
    /// PoolManager and come out as transferable ERC-6909 claims before graduation. Reproduced here by
    /// making the attacker trusted (the pre-fix behaviour), to show why the trust check is needed.
    function test_M1_bypassMechanicsWhenCallerTrusted() public {
        address t = _launch(address(usdc));
        pad.setTrustedCaller(address(attacker), true);
        attacker.run(0, t, address(usdc), 10e6);
        uint256 id = uint256(uint160(t));
        uint256 claims = pm.balanceOf(address(attacker), id);
        assertGt(claims, 0);
        assertFalse(pad.getLaunch(t).graduated);
        vm.prank(address(attacker));
        pm.transfer(bob, id, claims); // freely transferable shadow balance
        assertEq(pm.balanceOf(bob, id), claims);
    }

    function test_M1_buyForPoolManagerBlocked() public {
        address t = _launch(address(usdc));
        vm.expectRevert(HookLaunchpad.NotTrusted.selector);
        attacker.run(0, t, address(usdc), 10e6);
        assertEq(pm.balanceOf(address(attacker), uint256(uint160(t))), 0);
    }

    function test_M1_buyForOtherNeedsTrust() public {
        address t = _launch(address(usdc));
        vm.startPrank(alice);
        usdc.approve(address(pad), type(uint256).max);
        vm.expectRevert(HookLaunchpad.NotTrusted.selector);
        pad.buyWithQuoteFor(t, 1e6, 1, bob);
        pad.buyWithQuoteFor(t, 1e6, 1, alice); // to == caller stays open
        pad.buyWithQuote(t, 1e6, 1);
        vm.stopPrank();
        assertGt(HookToken(t).balanceOf(alice), 0);
        assertEq(HookToken(t).balanceOf(bob), 0);
    }

    /// A contract buying to itself inside an unlock can't forward the tokens to the PoolManager.
    function test_M1_nativeBuyThenForwardBlocked() public {
        address t = _launch(address(0));
        vm.expectRevert(HookToken.CurvePhaseTransfer.selector);
        attacker.run(1, t, address(0), 1 ether);
    }

    function test_setTrustedCaller_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pad.setTrustedCaller(alice, true);
        pad.setTrustedCaller(alice, true);
        assertTrue(pad.trustedCaller(alice));
        pad.setTrustedCaller(alice, false);
        assertFalse(pad.trustedCaller(alice));
    }

    // ---------------------------------------------------------------- L-2

    /// Tokens parked in the launchpad (e.g. sent by mistake) can't be sold by an arbitrary caller.
    function test_L2_sellDepositedOnlyTrusted() public {
        address t = _launch(address(usdc));
        vm.startPrank(alice);
        usdc.approve(address(pad), type(uint256).max);
        pad.buyWithQuote(t, 10e6, 0);
        HookToken(t).transfer(address(pad), 1_000 ether);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(HookLaunchpad.NotTrusted.selector);
        pad.sellDeposited(t, 1_000 ether, 0);

        pad.setTrustedCaller(bob, true);
        vm.prank(bob);
        pad.sellDeposited(t, 1_000 ether, 0);
        assertGt(usdc.balanceOf(bob), 0);
    }

    // ---------------------------------------------------------------- L-1: ManualPriceFeed

    // Times are absolute: via_ir may cache block.timestamp across vm.warp.
    uint256 constant T0 = 1_750_000_000;

    function test_L1_feedMoveCapAndForce() public {
        vm.warp(T0 + 1 hours);
        vm.expectRevert(ManualPriceFeed.MoveTooLarge.selector);
        usdFeed.setPrice(1.26e8); // +26% > 25%
        usdFeed.setPrice(1.25e8); // +25% ok
        vm.warp(T0 + 2 hours);
        vm.expectRevert(ManualPriceFeed.MoveTooLarge.selector);
        usdFeed.setPrice(0.9e8); // -28%
        usdFeed.forcePrice(0.5e8); // owner override
        (, int256 answer,,,) = usdFeed.latestRoundData();
        assertEq(answer, 0.5e8);
    }

    function test_L1_feedRateLimit() public {
        vm.warp(T0 + 1 hours);
        usdFeed.setPrice(1.01e8);
        vm.expectRevert(ManualPriceFeed.TooSoon.selector);
        usdFeed.setPrice(1.02e8);
        vm.warp(T0 + 1 hours + 5 minutes);
        usdFeed.setPrice(1.02e8);
    }

    function test_L1_feedKeeperRole() public {
        vm.warp(T0 + 1 hours);
        vm.prank(keeper);
        vm.expectRevert(ManualPriceFeed.NotKeeper.selector);
        usdFeed.setPrice(1.01e8);

        usdFeed.setKeeper(keeper);
        vm.prank(keeper);
        usdFeed.setPrice(1.01e8);

        vm.warp(T0 + 2 hours);
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        usdFeed.forcePrice(5e8);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        usdFeed.setLimits(10_000, 0);
        vm.expectRevert(ManualPriceFeed.BadPrice.selector);
        usdFeed.setPrice(0);
        vm.stopPrank();

        usdFeed.setLimits(10_000, 0);
        vm.prank(keeper);
        usdFeed.setPrice(2e8); // +98% within the raised cap
    }

    // ---------------------------------------------------------------- L-1: QuoteRegistry

    function test_L1_registryPriceBounds() public {
        registry.setPriceBounds(address(usdc), 0.9e18, 1.1e18);
        assertEq(registry.usdPrice(address(usdc)), 1e18);
        usdFeed.forcePrice(1.2e8);
        vm.expectRevert(QuoteRegistry.PriceOutOfBounds.selector);
        registry.usdPrice(address(usdc));
        vm.expectRevert(QuoteRegistry.PriceOutOfBounds.selector);
        registry.curveParams(address(usdc));
        usdFeed.forcePrice(0.8e8);
        vm.expectRevert(QuoteRegistry.PriceOutOfBounds.selector);
        registry.usdPrice(address(usdc));

        vm.expectRevert(QuoteRegistry.BadArgs.selector);
        registry.setPriceBounds(address(usdc), 2e18, 1e18);
        registry.setPriceBounds(address(usdc), 0.5e18, 0); // floor only
        assertEq(registry.usdPrice(address(usdc)), 0.8e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.setPriceBounds(address(usdc), 0, 0);
    }

    function test_L1_registryRejectsStaleAndFutureAnswers() public {
        vm.warp(T0 + 26 hours + 1);
        vm.expectRevert(QuoteRegistry.StalePrice.selector);
        registry.usdPrice(address(usdc));
        usdFeed.forcePrice(1e8);
        vm.warp(T0 + 26 hours); // answer dated in the future
        vm.expectRevert(QuoteRegistry.StalePrice.selector);
        registry.usdPrice(address(usdc));
    }

    function test_retireQuoteWithoutFeed() public {
        uint256 n = registry.quoteCount();
        registry.setQuote(address(usdc), false, address(0));
        (bool allowed,, address feed) = registry.quotes(address(usdc));
        assertFalse(allowed);
        assertEq(feed, address(0));
        vm.expectRevert(QuoteRegistry.QuoteNotAllowed.selector);
        registry.curveParams(address(usdc));

        // retiring works even with a dead feed, and re-listing doesn't duplicate the entry
        registry.setQuote(address(usdc), true, address(usdFeed));
        vm.warp(T0 + 30 hours);
        registry.setQuote(address(usdc), false, address(usdFeed));
        usdFeed.forcePrice(1e8);
        registry.setQuote(address(usdc), true, address(usdFeed));
        assertEq(registry.quoteCount(), n);

        vm.expectRevert(QuoteRegistry.BadArgs.selector);
        registry.setQuote(address(usdc), true, address(0));
    }
}
