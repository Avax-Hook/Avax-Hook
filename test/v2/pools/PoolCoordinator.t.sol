// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {QuoteRegistry} from "../../../contracts/QuoteRegistry.sol";
import {AvaxHookV2, IModuleSource} from "../../../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../../../contracts/v2/HookModuleRegistry.sol";
import {PoolCoordinatorV1, IPositionManagerLite} from "../../../contracts/v2/pools/PoolCoordinatorV1.sol";
import {PoolRouterV1} from "../../../contracts/v2/pools/PoolRouterV1.sol";
import {AvaxHookPoolsV1} from "../../../contracts/v2/pools/AvaxHookPoolsV1.sol";
import {NthBuyPotPoolsModule} from "../../../contracts/v2/pools/modules/NthBuyPotPoolsModule.sol";
import {AutoBurnModule} from "../../../contracts/v2/modules/AutoBurnModule.sol";
import {LpRewardsModule} from "../../../contracts/v2/modules/LpRewardsModule.sol";
import {DynamicFeeModule} from "../../../contracts/v2/modules/DynamicFeeModule.sol";
import {NthBuyPotModule} from "../../../contracts/v2/modules/NthBuyPotModule.sol";
import {WhaleGuardModule} from "../../../contracts/v2/modules/WhaleGuardModule.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {KingOfTheHillModule} from "../../../contracts/v2/modules/KingOfTheHillModule.sol";

/// A 1% fee-on-transfer token (v4 pools can't account for it; the coordinator must refuse its seed).
contract FotToken is ERC20 {
    constructor() ERC20("Fee", "FOT") {
        _mint(msg.sender, 1e27);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// Existing-token profile on an Avalanche mainnet fork: a second AvaxHookV2 instance bound to
/// PoolCoordinatorV1, real JOE / USDC, Uniswap's live PositionManager and Permit2.
contract PoolCoordinatorTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    QuoteRegistry constant LIVE_QUOTES = QuoteRegistry(0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1);
    IPositionManagerLite constant POSM = IPositionManagerLite(0xB74b1F14d2754AcfcbBe1a221023a5cf50Ab8ACD);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant FORK_BLOCK = 96_930_000;
    uint96 constant OPEN_FEE = 0.5 ether;

    HookModuleRegistry modules;
    AvaxHookV2 hook;
    PoolCoordinatorV1 coord;
    PoolRouterV1 router;
    uint32 burnId;
    uint32 lpId;
    uint32 dynId;
    uint32 potId;
    uint32 kothId;

    address treasury = makeAddr("treasury");
    address opener = makeAddr("opener");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")), FORK_BLOCK);
        modules = new HookModuleRegistry(address(this));
        uint160 flags = uint160((1 << 13) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(AvaxHookPoolsV1).creationCode,
            abi.encode(address(PM), address(this), address(modules), address(LIVE_QUOTES))
        );
        hook = new AvaxHookPoolsV1{salt: salt}(PM, address(this), IModuleSource(address(modules)), address(LIVE_QUOTES));
        modules.bindHook(address(hook));
        coord = new PoolCoordinatorV1(PM, hook, POSM, PERMIT2, address(this), treasury, OPEN_FEE);
        hook.bindLaunchpad(address(coord));
        assertTrue(coord.paused(), "deployed paused");
        coord.setConfig(treasury, OPEN_FEE, false);
        router = new PoolRouterV1(PM, address(hook));
        hook.bindRouter(address(router));
        coord.setQuote(USDC, true);

        burnId = modules.addModule(address(new AutoBurnModule(address(hook))), '{"name":"Auto burn"}');
        lpId = modules.addModule(address(new LpRewardsModule(address(hook))), '{"name":"LP rewards"}');
        dynId = modules.addModule(address(new DynamicFeeModule(address(hook))), '{"name":"Dynamic fee"}');
        potId = modules.addModule(address(new NthBuyPotPoolsModule(address(hook))), '{"name":"Nth buy pot"}');
        kothId = modules.addModule(address(new KingOfTheHillModule(address(hook))), '{"name":"KotH"}');

        vm.deal(opener, 1_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        deal(JOE, opener, 1_000_000 ether);
        deal(JOE, alice, 1_000_000 ether);
        deal(USDC, opener, 1_000_000e6);
        deal(USDC, alice, 1_000_000e6);
    }

    // ---------------------------------------------------------------- helpers

    /// sqrt(amount1 / amount0) in Q96 for a pool seeded with these amounts.
    function _sqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
    }

    function _args(address token, address quote, uint16 creatorFeeBps, uint32[] memory ids, bytes[] memory cfgs, uint256 seedToken, uint256 seedQuote)
        internal
        view
        returns (PoolCoordinatorV1.OpenArgs memory a)
    {
        a.token = token;
        a.quote = quote;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: creatorFeeBps, baseFeePips: 3_000});
        a.moduleIds = ids;
        a.moduleConfigs = cfgs;
        PoolKey memory key = coord.nextPoolKey(token, quote);
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        // 1 JOE = 0.001 AVAX / 1 JOE = 0.25 USDC style prices: just the seed ratio
        uint256 t = seedToken == 0 ? 10_000 ether : seedToken;
        uint256 q = seedQuote == 0 ? 10 ether : seedQuote;
        a.sqrtPriceX96 = tokenIs0 ? _sqrtPrice(t, q) : _sqrtPrice(q, t);
        a.seedToken = seedToken;
        a.seedQuote = seedQuote;
    }

    function _burnLp() internal view returns (uint32[] memory ids, bytes[] memory cfgs) {
        ids = new uint32[](2);
        cfgs = new bytes[](2);
        (ids[0], ids[1]) = (burnId, lpId);
        cfgs[0] = abi.encode(AutoBurnModule.Config(100)); // 1% of buy output burned
        cfgs[1] = abi.encode(LpRewardsModule.Config(100)); // 1% of buy input to LPs
    }

    function _openJoeAvax(uint16 creatorFeeBps) internal returns (PoolId id, uint256 nft, PoolKey memory key) {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), creatorFeeBps, ids, cfgs, 10_000 ether, 10 ether);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        (id, nft) = coord.openPool{value: OPEN_FEE + a.seedQuote}(a);
        vm.stopPrank();
        key = coord.poolKeyOf(id);
    }

    function _buy(address who, PoolKey memory key, uint256 avaxIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.swap{value: avaxIn}(key, true, avaxIn, 0, address(0), block.timestamp, "");
    }

    function _sell(address who, PoolKey memory key, uint256 joeIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(JOE).approve(address(router), joeIn);
        out = router.swap(key, false, joeIn, 0, address(0), block.timestamp, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- open

    function test_openWithNativeSeed() public {
        uint256 avaxBefore = opener.balance;
        uint256 joeBefore = IERC20(JOE).balanceOf(opener);
        (PoolId id, uint256 nft, PoolKey memory key) = _openJoeAvax(100);

        assertEq(IERC721(address(POSM)).ownerOf(nft), opener, "opener owns the seed NFT");
        assertGt(PM.getLiquidity(id), 0, "pool has liquidity");
        assertEq(key.tickSpacing, 60);
        assertEq(coord.feesOwed(), OPEN_FEE);
        // the seed ratio matches the price, so almost nothing is refunded; nothing stays in the coordinator
        assertApproxEqRel(avaxBefore - opener.balance, OPEN_FEE + 10 ether, 1e15);
        assertApproxEqRel(joeBefore - IERC20(JOE).balanceOf(opener), 10_000 ether, 1e15);
        assertEq(IERC20(JOE).balanceOf(address(coord)), 0);
        assertEq(address(coord).balance, OPEN_FEE);

        PoolCoordinatorV1.PoolRecord memory r = coord.record(id);
        assertEq(r.token, JOE);
        assertEq(r.quote, address(0));
        assertEq(r.creator, opener);
        assertTrue(hook.isOpen(id));
        assertEq(coord.poolsOfToken(JOE).length, 1);
        assertEq(coord.poolsOfCreator(opener).length, 1);
    }

    function test_openWithErc20QuoteSeed() public {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, USDC, 50, ids, cfgs, 10_000 ether, 2_500e6);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        IERC20(USDC).approve(address(coord), a.seedQuote);
        (PoolId id, uint256 nft) = coord.openPool{value: OPEN_FEE}(a);
        vm.stopPrank();
        assertEq(IERC721(address(POSM)).ownerOf(nft), opener);
        assertGt(PM.getLiquidity(id), 0);
        assertEq(IERC20(USDC).balanceOf(address(coord)), 0);
        assertEq(IERC20(JOE).balanceOf(address(coord)), 0);
    }

    function test_refusesOpenWithoutSeed() public {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, 0, 0);
        vm.startPrank(opener);
        vm.expectRevert(PoolCoordinatorV1.SeedRequired.selector);
        coord.openPool{value: OPEN_FEE}(a);
        // one-sided seeds are refused too
        a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 0);
        vm.expectRevert(PoolCoordinatorV1.SeedRequired.selector);
        coord.openPool{value: OPEN_FEE}(a);
        a = _args(JOE, address(0), 0, ids, cfgs, 0, 10 ether);
        vm.expectRevert(PoolCoordinatorV1.SeedRequired.selector);
        coord.openPool{value: OPEN_FEE + 10 ether}(a);
        // dust seeds below MIN_SEED_LIQUIDITY
        a = _args(JOE, address(0), 0, ids, cfgs, 1_000, 1);
        IERC20(JOE).approve(address(coord), a.seedToken);
        vm.expectRevert(PoolCoordinatorV1.SeedRequired.selector);
        coord.openPool{value: OPEN_FEE + 1}(a);
        vm.stopPrank();
    }

    function test_secondPoolSamePairGetsNextSpacing() public {
        _openJoeAvax(0);
        (, , PoolKey memory key2) = _openJoeAvax(0);
        assertEq(key2.tickSpacing, 61);
        assertEq(coord.poolsOfPair(JOE, address(0)).length, 2);
    }

    function test_reversePairSharesCounter() public {
        // USDC priced in JOE (JOE as quote) and JOE priced in USDC share one sorted pair counter
        coord.setQuote(JOE, true);
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(USDC, JOE, 0, ids, cfgs, 2_500e6, 10_000 ether);
        PoolCoordinatorV1.OpenArgs memory b = _args(JOE, USDC, 0, ids, cfgs, 10_000 ether, 2_500e6);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), type(uint256).max);
        IERC20(USDC).approve(address(coord), type(uint256).max);
        (PoolId id1,) = coord.openPool{value: OPEN_FEE}(a);
        b = _args(JOE, USDC, 0, ids, cfgs, 10_000 ether, 2_500e6);
        (PoolId id2,) = coord.openPool{value: OPEN_FEE}(b);
        vm.stopPrank();
        assertEq(coord.poolKeyOf(id1).tickSpacing, 60);
        assertEq(coord.poolKeyOf(id2).tickSpacing, 61);
        assertEq(coord.pairCount(JOE, USDC), 2);
        assertEq(coord.pairCount(USDC, JOE), 2);
    }

    function test_strayBalanceNotRefundedAndRescuable() public {
        deal(USDC, address(coord), 5_000e6); // sent by mistake
        vm.deal(address(coord), OPEN_FEE * 0 + 3 ether); // forced AVAX
        uint256 usdcBefore = IERC20(USDC).balanceOf(opener);
        uint256 avaxBefore = opener.balance;
        _openJoeAvax(0);
        assertApproxEqRel(avaxBefore - opener.balance, OPEN_FEE + 10 ether, 1e15, "no stray AVAX to the opener");
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, USDC, 0, ids, cfgs, 10_000 ether, 2_500e6);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        IERC20(USDC).approve(address(coord), a.seedQuote);
        coord.openPool{value: OPEN_FEE}(a);
        vm.stopPrank();
        assertLe(IERC20(USDC).balanceOf(opener), usdcBefore, "no stray USDC to the opener");
        assertGe(IERC20(USDC).balanceOf(address(coord)), 5_000e6);

        coord.rescue(USDC, alice, 5_000e6);
        assertEq(IERC20(USDC).balanceOf(alice), 1_000_000e6 + 5_000e6);
        vm.expectRevert(PoolCoordinatorV1.BadValue.selector);
        coord.rescue(address(0), alice, address(coord).balance); // the open fees stay
        coord.rescue(address(0), alice, address(coord).balance - coord.feesOwed());
        vm.prank(alice);
        vm.expectRevert();
        coord.rescue(USDC, alice, 1);
    }

    // ---------------------------------------------------------------- refusals

    function test_refusesTransferModule() public {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = kothId;
        cfgs[0] = abi.encode(KingOfTheHillModule.Config(0.1 ether, 500, 50, 3600, false));
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        vm.prank(opener);
        vm.expectRevert(PoolCoordinatorV1.TransferModuleNotAllowed.selector);
        coord.openPool{value: OPEN_FEE + 10 ether}(a);
    }

    function test_refusesCreatorFeeAboveOnePercent() public {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 101, ids, cfgs, 0, 0);
        vm.prank(opener);
        vm.expectRevert(PoolCoordinatorV1.CreatorFeeTooHigh.selector);
        coord.openPool{value: OPEN_FEE}(a);
    }

    function test_refusesUnknownQuoteWrongValuePausedNonToken() public {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        address usdt = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, usdt, 0, ids, cfgs, 0, 0);
        vm.startPrank(opener);
        vm.expectRevert(PoolCoordinatorV1.QuoteNotAllowed.selector);
        coord.openPool{value: OPEN_FEE}(a);

        a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        vm.expectRevert(PoolCoordinatorV1.BadValue.selector);
        coord.openPool{value: OPEN_FEE + 10 ether - 1}(a);

        a.token = alice; // no code
        vm.expectRevert(PoolCoordinatorV1.NotAToken.selector);
        coord.openPool{value: OPEN_FEE}(a);
        vm.stopPrank();

        coord.setConfig(treasury, OPEN_FEE, true);
        a = _args(JOE, address(0), 0, ids, cfgs, 0, 0);
        vm.prank(opener);
        vm.expectRevert(PoolCoordinatorV1.Paused.selector);
        coord.openPool{value: OPEN_FEE}(a);
    }

    function test_refusesFeeOnTransferSeed() public {
        vm.prank(opener);
        FotToken fot = new FotToken();
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolCoordinatorV1.OpenArgs memory a = _args(address(fot), address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        vm.startPrank(opener);
        fot.approve(address(coord), a.seedToken);
        vm.expectRevert(PoolCoordinatorV1.NotAToken.selector);
        coord.openPool{value: OPEN_FEE + a.seedQuote}(a);
        vm.stopPrank();
    }

    function test_onlyCoordinatorOpensHookPools() public {
        (uint32[] memory ids, bytes[] memory cfgs) = _burnLp();
        PoolKey memory key = coord.nextPoolKey(JOE, address(0));
        vm.expectRevert(AvaxHookV2.NotLaunchpad.selector);
        hook.registerPool(key, JOE, alice, AvaxHookV2.CoreConfig(0, 3_000), ids, cfgs);
    }

    // ---------------------------------------------------------------- trading

    function test_buySellWithModulesAndFees() public {
        (PoolId id, , PoolKey memory key) = _openJoeAvax(100);
        Currency avax = Currency.wrap(address(0));
        uint256 deadBefore = IERC20(JOE).balanceOf(DEAD);

        uint256 out = _buy(alice, key, 1 ether);
        assertGt(out, 0);
        assertGt(IERC20(JOE).balanceOf(DEAD), deadBefore, "auto burn burned JOE");
        // protocol 0.3% + creator 1% of the 1 AVAX input
        assertEq(hook.claimable(hook.PROTOCOL(), avax), 0.003 ether);
        assertEq(hook.claimable(opener, avax), 0.01 ether);

        uint256 back = _sell(alice, key, out);
        assertGt(back, 0);
        assertLt(back, 1 ether);

        uint256 tBefore = treasury.balance;
        hook.claimProtocol(avax); // pays the coordinator's protocol recipient
        assertGt(treasury.balance - tBefore, 0.003 ether);

        uint256 oBefore = opener.balance;
        vm.prank(opener);
        hook.claim(avax, opener);
        assertGt(opener.balance, oBefore);
        assertTrue(hook.isOpen(id));
    }

    function test_quoteMatchesSwap() public {
        (, , PoolKey memory key) = _openJoeAvax(100);
        (uint256 qOut, uint256 used, bool wouldRevert,) = router.quote(key, true, 1 ether, alice, address(0), "");
        assertFalse(wouldRevert);
        assertEq(used, 1 ether);
        uint256 out = _buy(alice, key, 1 ether);
        assertEq(qOut, out, "buy quote exact");

        (uint256 qSell,,,) = router.quote(key, false, out, alice, address(0), "");
        uint256 back = _sell(alice, key, out);
        assertEq(qSell, back, "sell quote exact");
    }

    function test_quoteReportsModuleRefusal() public {
        uint32 wgId = modules.addModule(address(new WhaleGuardModule(address(hook))), '{"name":"Whale guard"}');
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = wgId;
        cfgs[0] = abi.encode(WhaleGuardModule.Config(1_000, 0.5 ether));
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        (PoolId id,) = coord.openPool{value: OPEN_FEE + a.seedQuote}(a);
        vm.stopPrank();
        PoolKey memory key = coord.poolKeyOf(id);

        (, , bool small,) = router.quote(key, true, 0.4 ether, alice, address(0), "");
        assertFalse(small, "under the cap");
        (, , bool big, bytes memory reason) = router.quote(key, true, 1 ether, alice, address(0), "");
        assertTrue(big, "whale guard refuses");
        assertGt(reason.length, 0);
        vm.prank(alice);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, true, 1 ether, 0, address(0), block.timestamp, "");

        // an unopened pool key is reported, not thrown
        key.tickSpacing = 1;
        (, , bool none,) = router.quote(key, true, 1 ether, alice, address(0), "");
        assertTrue(none);
    }

    function test_routerRefusesForeignHookPool() public {
        (, , PoolKey memory key) = _openJoeAvax(0);
        key.hooks = AvaxHookV2(payable(address(0x1234)));
        vm.prank(alice);
        vm.expectRevert(PoolRouterV1.BadPool.selector);
        router.swap{value: 1 ether}(key, true, 1 ether, 0, address(0), block.timestamp, "");
    }

    function test_slippageAndDeadline() public {
        (, , PoolKey memory key) = _openJoeAvax(0);
        vm.prank(alice);
        vm.expectRevert(PoolRouterV1.Slippage.selector);
        router.swap{value: 1 ether}(key, true, 1 ether, type(uint256).max, address(0), block.timestamp, "");
        vm.prank(alice);
        vm.expectRevert(PoolRouterV1.Expired.selector);
        router.swap{value: 1 ether}(key, true, 1 ether, 0, address(0), block.timestamp - 1, "");
    }

    function test_dynamicFeeAndPotRun() public {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (dynId, potId);
        cfgs[0] = abi.encode(DynamicFeeModule.Config(50_000, 5));
        cfgs[1] = abi.encode(NthBuyPotModule.Config(200, 2, 0.01 ether));
        PoolCoordinatorV1.OpenArgs memory a = _args(JOE, address(0), 0, ids, cfgs, 10_000 ether, 10 ether);
        vm.startPrank(opener);
        IERC20(JOE).approve(address(coord), a.seedToken);
        (PoolId id,) = coord.openPool{value: OPEN_FEE + a.seedQuote}(a);
        vm.stopPrank();
        PoolKey memory key = coord.poolKeyOf(id);
        uint256 small = _buy(alice, key, 0.05 ether);
        vm.roll(block.number + 1);
        _buy(bob, key, 0.05 ether);
        assertGt(small, 0);
        // a big trade pays a higher fee rate (dynamic fee): fewer tokens per AVAX
        vm.roll(block.number + 1);
        (uint256 qSmall,,,) = router.quote(key, true, 0.05 ether, alice, address(0), "");
        (uint256 qBig,,,) = router.quote(key, true, 5 ether, alice, address(0), "");
        assertLt(qBig * 1e18 / 5 ether, qSmall * 1e18 / 0.05 ether);
    }

    // ---------------------------------------------------------------- liquidity rules

    function _approveLp(address who) internal {
        vm.startPrank(who);
        IERC20(JOE).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(JOE, address(POSM), type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _mintFor(address who, PoolKey memory key, int24 lower, int24 upper, uint256 liquidity, bool expectFail) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lower, upper, liquidity, uint128(100 ether), uint128(100_000 ether), who, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), who);
        vm.prank(who);
        if (expectFail) vm.expectRevert(); // FullRangeOnly, wrapped by the PoolManager
        POSM.modifyLiquidities{value: 100 ether}(abi.encode(actions, params), block.timestamp);
    }

    function test_outsideLpFullRangeOnly() public {
        (PoolId id, , PoolKey memory key) = _openJoeAvax(0);
        uint128 before = PM.getLiquidity(id);
        int24 lo = TickMath.minUsableTick(key.tickSpacing);
        int24 hi = TickMath.maxUsableTick(key.tickSpacing);
        _approveLp(alice);
        _mintFor(alice, key, lo, hi, 1e18, false);
        assertEq(PM.getLiquidity(id), before + 1e18, "full-range add works");
        _mintFor(alice, key, -600, 600, 1e18, true);
    }

    // ---------------------------------------------------------------- admin

    function test_sendFeesAndVerified() public {
        (PoolId id, , ) = _openJoeAvax(0);
        uint256 before = treasury.balance;
        coord.sendFees();
        assertEq(treasury.balance - before, OPEN_FEE);
        assertEq(coord.feesOwed(), 0);
        vm.expectRevert(PoolCoordinatorV1.BadValue.selector);
        coord.sendFees();

        coord.setVerified(id, true);
        assertTrue(coord.record(id).verified);
        vm.prank(alice);
        vm.expectRevert();
        coord.setVerified(id, false);
    }

    function test_poolsPage() public {
        _openJoeAvax(0);
        _openJoeAvax(0);
        (PoolId[] memory ids, PoolCoordinatorV1.PoolRecord[] memory recs) = coord.poolsPage(0, 10);
        assertEq(ids.length, 2);
        assertEq(recs[0].tickSpacing, 61, "newest first");
        assertEq(coord.poolCount(), 2);
    }
}
