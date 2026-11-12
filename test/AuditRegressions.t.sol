// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";

/// Calls the PoolManager directly, the way a third-party router or attacker would.
contract DirectCaller is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    struct Op {
        uint8 kind; // 0 swap, 1 add liquidity
        PoolKey key;
        SwapParams swap;
        ModifyLiquidityParams liq;
        bytes hookData;
        uint8 repeat;
    }

    function run(Op calldata op) external payable {
        pm.unlock(abi.encode(op));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        Op memory op = abi.decode(data, (Op));
        for (uint256 i; i < (op.repeat == 0 ? 1 : op.repeat); ++i) {
            BalanceDelta d = op.kind == 0 ? pm.swap(op.key, op.swap, op.hookData) : _liq(op);
            _settle(op.key.currency0, d.amount0());
            _settle(op.key.currency1, d.amount1());
        }
        return "";
    }

    function _liq(Op memory op) internal returns (BalanceDelta d) {
        (d,) = pm.modifyLiquidity(op.key, op.liq, "");
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            uint256 owe = uint256(uint128(-amt));
            if (c.isAddressZero()) {
                pm.settle{value: owe}();
            } else {
                pm.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(pm), owe);
                pm.settle();
            }
        } else if (amt > 0) {
            pm.take(c, address(this), uint256(uint128(amt)));
        }
    }
}

contract Btc8 is ERC20 {
    constructor() ERC20("Bitcoin", "BTCb") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// One test per finding of the internal review (AUDIT-INTERNAL.md), on an Avalanche fork.
contract AuditRegressionsTest is Test {
    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant AVAX_USD = 0x0A77230d17318075983913bC2145DB16C7366156;

    AvaxHook hook;
    HookLaunchpad pad;
    AvaxHookRouter router;
    QuoteRegistry registry;
    DirectCaller direct;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

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
        direct = new DirectCaller(PM);
        vm.deal(alice, 10_000 ether);
        vm.deal(creator, 100 ether);
        vm.deal(address(direct), 10_000 ether);
    }

    function _cfg() internal pure returns (AvaxHook.HookConfig memory c) {
        c.baseFeePips = 3_000;
        c.maxFeePips = 3_000;
    }

    function _graduated(AvaxHook.HookConfig memory c) internal returns (HookToken t, PoolKey memory key) {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "R";
        a.symbol = "R";
        a.hook = c;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookToken(pad.launch{value: fee}(a));
        vm.prank(alice);
        pad.buy{value: 200 ether}(address(t), 0);
        assertTrue(pad.getLaunch(address(t)).graduated);
        key = pad.poolKey(address(t));
    }

    function _swapOp(PoolKey memory key, bool buy, int256 amountSpecified, uint160 limit, bytes memory hookData, uint8 repeat)
        internal
        pure
        returns (DirectCaller.Op memory op)
    {
        op.kind = 0;
        op.key = key;
        op.swap = SwapParams({zeroForOne: buy, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit});
        op.hookData = hookData;
        op.repeat = repeat;
    }

    // HK-1: exact-output swaps are refused, so no cut can be skipped.
    function test_HK1_exactOutputRefused() public {
        (, PoolKey memory key) = _graduated(_cfg());
        DirectCaller.Op memory op = _swapOp(key, true, 1_000_000 ether, TickMath.MIN_SQRT_PRICE + 1, "", 1);
        vm.expectRevert();
        direct.run(op);
    }

    // HK-3 / L-02: a price-limited partial buy is refused (it can't qualify for pots or cap griefing).
    function test_HK3_partialFillBuyRefused() public {
        (, PoolKey memory key) = _graduated(_cfg());
        DirectCaller.Op memory op = _swapOp(key, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1_000_000, "", 1);
        vm.expectRevert();
        direct.run(op);
    }

    // HK-3: hookData from anyone but the AvaxHook router is ignored: no spoofed pot winner.
    function test_HK3_spoofedBuyerCantWinPot() public {
        AvaxHook.HookConfig memory c = _cfg();
        c.potBps = 500;
        c.potEveryNBuys = 2;
        c.potMinBuy = 0.1 ether;
        (, PoolKey memory key) = _graduated(c);
        for (uint256 i; i < 4; ++i) {
            vm.roll(block.number + 1);
            direct.run(_swapOp(key, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1, abi.encode(alice), 1));
        }
        assertEq(hook.claimable(alice, Currency.wrap(address(0))), 0);
    }

    // HK-4: the whale cap covers the whole transaction, not each swap.
    function test_HK4_whaleCapIsPerTransaction() public {
        AvaxHook.HookConfig memory c = _cfg();
        c.whaleBlocks = 100;
        c.maxBuyPerTx = 2 ether;
        (, PoolKey memory key) = _graduated(c);
        vm.expectRevert();
        direct.run(_swapOp(key, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1, "", 3)); // 3 × 1 AVAX in one tx
        direct.run(_swapOp(key, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1, "", 2)); // 2 AVAX is fine
    }

    // HK-8: no concentrated (JIT) liquidity from outsiders.
    function test_HK8_outsideLiquidityFullRangeOnly() public {
        (HookToken t, PoolKey memory key) = _graduated(_cfg());
        vm.prank(alice);
        t.transfer(address(direct), 1_000_000 ether);
        DirectCaller.Op memory op;
        op.kind = 1;
        op.key = key;
        op.liq = ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0});
        vm.expectRevert();
        direct.run(op);
    }

    // LP-1: a quote whose unit is worth a lot either graduates fine or is refused at launch — the
    // curve can never fill and then lock funds.
    function test_LP1_highUnitValueQuoteNeverLocksFunds() public {
        Btc8 btc = new Btc8();
        ManualPriceFeed feed = new ManualPriceFeed(address(this), "BTC / USD", 8, 100_000e8);
        registry.setQuote(address(btc), true, address(feed));
        registry.setFdv(2_500e8, 50_000e8);
        btc.mint(alice, 1e10);
        HookLaunchpad.LaunchArgs memory a;
        a.name = "B";
        a.symbol = "B";
        a.quote = address(btc);
        a.hook = _cfg();
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        try pad.launch{value: fee}(a) returns (address t) {
            vm.startPrank(alice);
            btc.approve(address(pad), type(uint256).max);
            pad.buyWithQuote(t, 1e8, 0);
            vm.stopPrank();
            assertTrue(pad.getLaunch(t).graduated, "filled curve must graduate");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), HookLaunchpad.UnreachablePrice.selector);
        }
    }

    // LP-3: a completing buy can't be gas-starved into deferring graduation.
    function test_LP3_completingBuyNeedsGraduationGas() public {
        HookLaunchpad.LaunchArgs memory a;
        a.name = "G";
        a.symbol = "G";
        a.hook = _cfg();
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        address t = pad.launch{value: fee}(a);
        vm.prank(alice);
        (bool ok,) = address(pad).call{value: 200 ether, gas: 400_000}(abi.encodeCall(HookLaunchpad.buy, (t, 0)));
        assertFalse(ok);
        assertFalse(pad.getLaunch(t).complete);
    }

    // LP-4: the blueprint royalty comes out of the creator fee, not the protocol fee.
    function test_LP4_royaltyFromCreatorFee() public {
        AvaxHook.HookConfig memory c = _cfg();
        c.creatorFeeBps = 0;
        vm.prank(alice);
        uint32 id = pad.saveBlueprint("Rebate", c, 2_000);
        HookLaunchpad.LaunchArgs memory a;
        a.name = "Q";
        a.symbol = "Q";
        a.blueprintId = id;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        address t = pad.launch{value: fee}(a);
        vm.prank(creator);
        pad.buy{value: 10 ether}(t, 0);
        assertEq(pad.claimable(alice, address(0)), 0); // no creator fee, nothing to rebate
        assertEq(pad.claimable(treasury, address(0)), fee + (10 ether * 30) / 10_000);
    }

    // HK-2: a pump right before a buyback (here in the same block) can't be sold into it: the buyback's
    // price bound comes from an aged reference, and only the keeper can trigger it.
    function test_HK2_buybackRefusedAfterPump() public {
        AvaxHook.HookConfig memory c = _cfg();
        c.buybackBps = 500;
        c.buybackMaxSpend = 1 ether;
        (HookToken t, PoolKey memory key) = _graduated(c);
        vm.startPrank(alice);
        t.approve(address(router), type(uint256).max);
        router.sell(address(t), t.balanceOf(alice) / 4, 0, block.timestamp);
        vm.stopPrank();
        vm.roll(block.number + 2 * uint256(hook.REF_MIN_AGE_BLOCKS()) + 1);
        vm.prank(alice);
        router.buy{value: 1 wei}(address(t), 1 wei, 0, address(0), block.timestamp); // checkpoints the price
        vm.roll(block.number + hook.REF_MIN_AGE_BLOCKS());
        vm.prank(alice);
        router.buy{value: 30 ether}(address(t), 30 ether, 0, address(0), block.timestamp); // attacker's front-run
        vm.prank(alice);
        vm.expectRevert(AvaxHook.NotKeeper.selector);
        hook.executeBuyback(key);
        vm.expectRevert(AvaxHook.BuybackNotReady.selector);
        hook.executeBuyback(key); // spot is past 5% above the aged reference: nothing to buy
    }
}
