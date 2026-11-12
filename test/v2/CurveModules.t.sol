// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {HookLensV2} from "../../contracts/v2/HookLensV2.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {HookModuleBase} from "../../contracts/v2/modules/HookModuleBase.sol";
import {MaxPerWalletModule} from "../../contracts/v2/modules/MaxPerWalletModule.sol";
import {V2Base} from "./V2Base.t.sol";
import {ProbeModule} from "./V2Mocks.sol";

/// Curve-phase test module: credits to a chosen destination from each side, extra fee, a per-buy cap,
/// refusals, and a record of the last context it saw.
contract CurveProbe is HookModuleBase {
    uint16 public caps;
    address public dest; // credit recipient: this, BURN or LP_DONATE
    uint256 public beforeBps;
    uint256 public afterBps;
    uint24 public fee;
    uint256 public maxBuy; // buys above this revert (0 = no cap)
    bool public refuse; // revert every swap callback

    uint8 public phase;
    address public trader;
    address public sender;
    address public referrer;
    bytes public extra;
    uint256 public amountIn;
    uint256 public amountOut;
    uint160 public priceBefore;
    uint160 public priceAfter;
    uint256 public txSwaps;
    uint256 public txVolume;

    error TooBig();
    error Refused();

    constructor(address _hook, uint16 _caps) HookModuleBase(_hook) {
        caps = _caps;
        dest = address(this);
    }

    function set(address _dest, uint256 _beforeBps, uint256 _afterBps, uint24 _fee) external {
        (dest, beforeBps, afterBps, fee) = (_dest, _beforeBps, _afterBps, _fee);
    }

    function setRules(uint256 _maxBuy, bool _refuse) external {
        (maxBuy, refuse) = (_maxBuy, _refuse);
    }

    function capabilities() external view override returns (uint16) {
        return caps;
    }

    function validateConfig(bytes calldata) public pure override {}

    function onRegister(PoolId, address, address, address, bytes calldata) external override onlyHook {}

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (refuse) revert Refused();
        if (ctx.isBuy && maxBuy != 0 && ctx.txVolume > maxBuy) revert TooBig();
        (phase, trader, sender, referrer, extra) = (ctx.phase, ctx.trader, ctx.sender, ctx.referrer, ctx.extra);
        (amountIn, priceBefore, txSwaps, txVolume) = (ctx.amountIn, ctx.sqrtPriceX96, ctx.txSwaps, ctx.txVolume);
        uint256 c = (ctx.amountIn * beforeBps) / BPS;
        return (fee, c == 0 ? new Credit[](0) : _one(dest, c));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (refuse) revert Refused();
        (amountOut, priceAfter) = (ctx.amountOut, ctx.sqrtPriceX96);
        uint256 c = (ctx.amountOut * afterBps) / BPS;
        return c == 0 ? new Credit[](0) : _one(dest, c);
    }

    function claimFrom(Currency c) external {
        AvaxHookV2(payable(hook)).claim(c, address(this));
    }

    receive() external payable {}
}

/// Bonding-curve trades run the pool's swap modules (phase = curve).
contract CurveModulesTest is V2Base {
    using StateLibrary for IPoolManager;

    uint16 constant SWAP = ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    function _ids(uint32 a) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](1);
        ids[0] = a;
    }

    function _cfgs(bytes memory a) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = a;
    }

    function _curveProbe(uint16 caps) internal returns (CurveProbe p, uint32 id) {
        p = new CurveProbe(address(hook), caps);
        id = modules.addModule(address(p), '{"name":"curve probe"}');
    }

    function _launchCurveProbe(uint16 caps) internal returns (CurveProbe p, HookTokenV2 t) {
        uint32 id;
        (p, id) = _curveProbe(caps);
        t = _launch(_ids(id), _cfgs(""), 100);
    }

    function _buy(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 got) {
        uint256 b0 = t.balanceOf(who);
        vm.prank(who);
        pad.buy{value: amt}(address(t), 0);
        got = t.balanceOf(who) - b0;
    }

    function _sell(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        uint256 b0 = who.balance;
        vm.prank(who);
        pad.sell(address(t), amt, 0);
        out = who.balance - b0;
    }

    function _spotSqrt(HookTokenV2 t) internal view returns (uint160) {
        HookLaunchpadV2.Launch memory l = pad.getLaunch(address(t));
        return pad.curveSqrtPrice(l.quote, address(t), uint256(l.virtualQuote) + l.reserve, uint256(l.virtualTokens) - l.tokensSold);
    }

    /// Launchpad's AVAX covers every curve obligation; the hook's balances back its plain-balance claims.
    function _assertSolvent(HookTokenV2 t, address[] memory claimers) internal view {
        HookLaunchpadV2.Launch memory l = pad.getLaunch(address(t));
        uint256 owed = uint256(l.reserve) + l.bonus + pad.claimable(creator, address(0)) + pad.claimable(treasury, address(0));
        assertGe(address(pad).balance, owed, "pad AVAX solvent");
        if (!l.graduated) assertEq(t.balanceOf(address(pad)), 1_000_000_000 ether - l.tokensSold, "pad tokens = unsold");
        uint256 sumNative;
        uint256 sumToken;
        for (uint256 i; i < claimers.length; ++i) {
            sumNative += hook.claimable(claimers[i], NATIVE);
            sumToken += hook.claimable(claimers[i], Currency.wrap(address(t)));
        }
        assertEq(hook.held(NATIVE), sumNative, "held AVAX = claims");
        assertGe(address(hook).balance, hook.held(NATIVE), "hook AVAX backs held");
        assertEq(hook.held(Currency.wrap(address(t))), sumToken, "held tokens = claims");
        assertEq(t.balanceOf(address(hook)), sumToken, "hook tokens back held");
    }

    // ---------------------------------------------------------------- context

    function test_curveContext() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        uint160 before = _spotSqrt(t);
        uint256 got = _buy(alice, t, 2 ether);
        assertEq(p.phase(), ModuleCaps.PHASE_CURVE);
        assertEq(p.trader(), alice);
        assertEq(p.sender(), alice);
        assertEq(p.amountIn(), 2 ether);
        assertEq(p.amountOut(), got); // no cuts: what the curve paid out
        assertEq(p.priceBefore(), before);
        assertEq(p.priceAfter(), _spotSqrt(t));
        // AVAX is currency0, so a buy lowers sqrt(token per AVAX)
        assertLt(p.priceAfter(), p.priceBefore());
        // market cap from the context price = 1B tokens at the curve's spot price
        HookLaunchpadV2.Launch memory l = pad.getLaunch(address(t));
        uint256 spotMc = (1_000_000_000 ether * (uint256(l.virtualQuote) + l.reserve)) / (uint256(l.virtualTokens) - l.tokensSold);
        uint256 mc = (((1_000_000_000 ether << 96) / p.priceAfter()) << 96) / p.priceAfter();
        assertApproxEqRel(mc, spotMc, 1e12);
        // per-tx counters are shared with pool swaps (forge runs the test as one transaction)
        uint256 s0 = p.txSwaps();
        vm.prank(bob);
        pad.buyWithData{value: 1 ether}(address(t), 1 ether, 0, carol, hex"beef");
        assertEq(p.trader(), bob);
        assertEq(p.referrer(), carol);
        assertEq(p.extra(), hex"beef");
        assertEq(p.txSwaps(), s0 + 1);
        assertEq(p.txVolume(), 3 ether);
        vm.prank(alice);
        pad.sellWithData(address(t), got / 2, 0, hex"01");
        assertEq(p.extra(), hex"01");
        assertEq(p.amountIn(), got / 2);
        assertEq(p.txSwaps(), s0 + 2);
        // after graduation the same module sees pool swaps
        PoolKey memory key = _graduate(t);
        _routerBuy(alice, t, 1 ether);
        assertEq(p.phase(), ModuleCaps.PHASE_POOL);
        (uint160 sp,,,) = PM.getSlot0(_id(key));
        assertGt(sp, 0);
        assertGt(hook.launchedAt(_id(key)), 0);
        // only the launchpad drives curve callbacks
        AvaxHookV2.CurveTrade memory ct;
        vm.expectRevert(AvaxHookV2.NotLaunchpad.selector);
        hook.curveSwap(ct);
    }

    function test_trustedCallerBuyNamesRecipient() public {
        (CurveProbe p,) = _curveProbe(SWAP);
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Usd";
        a.symbol = "USD";
        a.quote = USDC;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 100, baseFeePips: 3_000});
        a.moduleIds = _ids(modules.idOf(address(p)));
        a.moduleConfigs = _cfgs("");
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        HookTokenV2 t = HookTokenV2(pad.launch{value: fee}(a));
        address orders = makeAddr("orders");
        pad.setTrustedCaller(orders, true);
        deal(USDC, orders, 1_000e6);
        vm.startPrank(orders);
        IERC20(USDC).approve(address(pad), type(uint256).max);
        pad.buyWithQuoteFor(address(t), 100e6, 0, alice);
        vm.stopPrank();
        assertEq(p.trader(), alice);
        assertEq(p.sender(), orders);
        assertEq(p.amountIn(), 100e6);
        // ERC-20 credits move to the hook too
        p.set(address(p), 1_000, 0, 0);
        vm.prank(orders);
        pad.buyWithQuoteFor(address(t), 100e6, 0, bob);
        assertEq(hook.claimable(address(p), Currency.wrap(USDC)), 10e6);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 10e6);
        p.claimFrom(Currency.wrap(USDC));
        assertEq(IERC20(USDC).balanceOf(address(p)), 10e6);
    }

    // ---------------------------------------------------------------- King of the Hill on the curve

    function test_kothCrownedAndPaidOnCurve() public {
        HookTokenV2 t = _launch(_ids(kothId), _cfgs(_kothCfg(1 ether, 500, 100, 0, false)), 100);
        _buy(alice, t, 2 ether);
        (address king, uint256 winning,,) = koth.currentKing(address(t));
        assertEq(king, alice);
        assertEq(winning, 2 ether);
        // a smaller buy pays the King 1% of its input
        uint256 got = _buy(bob, t, 1 ether);
        assertEq(hook.claimable(alice, NATIVE), 0.01 ether);
        // a curve sell pays the King 1% of the gross output
        uint256 before = hook.claimable(alice, NATIVE);
        _sell(bob, t, got);
        assertGt(hook.claimable(alice, NATIVE), before);
        // the King claims AVAX before graduation (plain balance in the hook)
        uint256 owed = hook.claimable(alice, NATIVE);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        hook.claim(NATIVE, alice);
        assertEq(alice.balance - b0, owed);
        assertEq(hook.held(NATIVE), 0);
        // the King selling on the curve gives up the crown
        uint256 bal = t.balanceOf(alice);
        _sell(alice, t, bal / 2);
        (king,,,) = koth.currentKing(address(t));
        assertEq(king, address(0));
        // the creator can't be King
        vm.prank(creator);
        pad.buy{value: 5 ether}(address(t), 0);
        (king,,,) = koth.currentKing(address(t));
        assertEq(king, address(0));
        // dev buy at launch runs the modules too (creatorCanBeKing)
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Dev";
        a.symbol = "DEV";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 0, baseFeePips: 3_000});
        a.moduleIds = _ids(kothId);
        a.moduleConfigs = _cfgs(_kothCfg(1 ether, 500, 100, 0, true));
        a.devBuy = 3 ether;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        HookTokenV2 t2 = HookTokenV2(pad.launch{value: fee + 3 ether}(a));
        (king,,,) = koth.currentKing(address(t2));
        assertEq(king, creator);
    }

    // ---------------------------------------------------------------- caps and refusals

    function test_maxPerWalletAndBuyCapOnCurve() public {
        (CurveProbe p, uint32 pid) = _curveProbe(ModuleCaps.BEFORE_SWAP);
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (mpwId, pid);
        (cfgs[0], cfgs[1]) = (_mpwCfg(100, 0), bytes("")); // 1% wallet cap
        HookTokenV2 t = _launch(ids, cfgs, 100);
        p.setRules(3 ether, false);
        // per-buy (per-tx) cap
        vm.prank(alice);
        vm.expectRevert(CurveProbe.TooBig.selector);
        pad.buy{value: 4 ether}(address(t), 0);
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), 4 ether, alice);
        assertTrue(q.wouldRevert);
        assertEq(bytes4(q.reason), CurveProbe.TooBig.selector);
        // wallet cap: 10M tokens
        p.setRules(0, false);
        vm.prank(alice);
        vm.expectRevert();
        pad.buy{value: 1_000 ether}(address(t), 0);
        uint256 got = _buy(alice, t, 1 ether);
        assertLe(got, 10_000_000 ether);
    }

    function test_blocksSellsModuleRefusesCurveSells() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP | ModuleCaps.BLOCKS_SELLS);
        uint256 got = _buy(alice, t, 2 ether);
        p.setRules(0, true);
        vm.prank(alice);
        vm.expectRevert(CurveProbe.Refused.selector);
        pad.sell(address(t), got, 0);
        HookLensV2.Quote memory q = lens.quoteSell(address(t), got, alice);
        assertTrue(q.wouldRevert);
        assertEq(bytes4(q.reason), CurveProbe.Refused.selector);
    }

    function test_brokenModuleCantBrickCurveSells() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        uint256 got = _buy(alice, t, 2 ether);
        p.setRules(0, true);
        vm.prank(bob);
        vm.expectRevert(CurveProbe.Refused.selector); // buys: the rule's business
        pad.buy{value: 1 ether}(address(t), 0);
        uint256 out = _sell(alice, t, got); // sells: isolated, the revert is ignored
        assertGt(out, 1.9 ether);
    }

    /// Over-cap credits on the curve are scaled down to the 25% cap (rules M), never a revert.
    function test_overCapCreditsOnCurve() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        uint256 got = _buy(alice, t, 2 ether);
        p.set(address(p), 5_000, 5_000, 0); // 50% > MAX_MODULE_CUT_BPS on both sides
        Currency tc = Currency.wrap(address(t));
        _buy(bob, t, 1 ether);
        assertEq(hook.claimable(address(p), NATIVE), p.amountIn() / 4);
        assertEq(hook.claimable(address(p), tc), p.amountOut() / 4);
        uint256 n0 = hook.claimable(address(p), NATIVE);
        uint256 k0 = hook.claimable(address(p), tc);
        uint256 q = lens.quoteSell(address(t), got, alice).out;
        uint256 out = _sell(alice, t, got);
        assertEq(out, q);
        assertEq(hook.claimable(address(p), tc) - k0, got / 4);
        assertEq(hook.claimable(address(p), NATIVE) - n0, p.amountOut() / 4);
        address[] memory cl = new address[](4);
        (cl[0], cl[1], cl[2], cl[3]) = (address(p), creator, hook.PROTOCOL(), alice);
        _assertSolvent(t, cl);
    }

    // ---------------------------------------------------------------- credits

    function test_curveCreditsBothSidesAndClaims() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        p.set(address(p), 1_000, 1_000, 0); // 10% of each side to itself
        Currency T = Currency.wrap(address(t));
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), 10 ether, alice);
        uint256 got = _buy(alice, t, 10 ether);
        assertEq(got, q.out, "lens = buy");
        assertEq(hook.claimable(address(p), NATIVE), 1 ether);
        assertEq(q.inCut, 1 ether);
        uint256 curveOut = p.amountOut();
        assertEq(hook.claimable(address(p), T), curveOut / 10);
        assertEq(got, curveOut - curveOut / 10);
        assertEq(q.outCut, curveOut / 10);
        // sell: 10% of the tokens, then 10% of the quote
        q = lens.quoteSell(address(t), got, alice);
        uint256 out = _sell(alice, t, got);
        assertEq(out, q.out, "lens = sell");
        address[] memory cl = new address[](1);
        cl[0] = address(p);
        _assertSolvent(t, cl);
        // AVAX claims pay out on the curve; token claims wait for graduation (transfer lock)
        p.claimFrom(NATIVE);
        assertEq(hook.held(NATIVE), 0);
        vm.expectRevert(HookTokenV2.CurvePhaseTransfer.selector);
        p.claimFrom(T);
        p.set(address(p), 0, 0, 0);
        _graduate(t);
        uint256 owed = hook.claimable(address(p), T);
        p.claimFrom(T);
        assertEq(t.balanceOf(address(p)), owed);
    }

    function test_curveBurnDonateAndExtraFee() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        // burn 5% of each side, 2% extra fee
        p.set(DEAD, 500, 500, 20_000);
        uint256 dead0 = DEAD.balance;
        uint256 bonus0 = pad.getLaunch(address(t)).bonus;
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), 10 ether, alice);
        uint256 got = _buy(alice, t, 10 ether);
        assertEq(got, q.out);
        assertEq(q.extraFee, 0.2 ether);
        assertEq(DEAD.balance - dead0, 0.5 ether);
        assertEq(t.balanceOf(DEAD), p.amountOut() / 20);
        assertEq(pad.getLaunch(address(t)).bonus - bonus0, 0.2 ether);
        // LP_DONATE: quote to the graduation liquidity, tokens burned
        p.set(ModuleCaps.LP_DONATE, 500, 500, 0);
        uint256 tdead = t.balanceOf(DEAD);
        bonus0 = pad.getLaunch(address(t)).bonus;
        _buy(bob, t, 10 ether);
        assertEq(pad.getLaunch(address(t)).bonus - bonus0, 0.5 ether);
        assertEq(t.balanceOf(DEAD) - tdead, p.amountOut() / 20);
        q = lens.quoteSell(address(t), got, alice);
        assertEq(_sell(alice, t, got), q.out);
        _assertSolvent(t, new address[](0));
        // graduation still exact with burned/donated amounts
        _graduate(t);
        assertEq(pad.getLaunch(address(t)).tokensSold, 800_000_000 ether);
        assertEq(t.balanceOf(address(pad)), 0);
    }

    /// Random curve trades with random module cuts: the launchpad and hook stay solvent, a buy then a sell of
    /// everything bought never profits.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_curveCreditsSolvency(uint256 seed) public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        address[3] memory who = [alice, bob, carol];
        address[] memory cl = new address[](1);
        cl[0] = address(p);
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address dest = r % 3 == 0 ? address(p) : r % 3 == 1 ? DEAD : ModuleCaps.LP_DONATE;
            p.set(dest, (r >> 8) % 2_501, (r >> 24) % 2_501, uint24((r >> 40) % 400_000));
            address w = who[(r >> 64) % 3];
            uint256 bal = t.balanceOf(w);
            if ((r >> 72) % 3 != 0 || bal == 0) {
                uint256 amt = 1 + ((r >> 80) % 300 ether);
                uint256 a0 = w.balance;
                HookLensV2.Quote memory q = lens.quoteBuy(address(t), amt, w);
                uint256 got = _buy(w, t, amt);
                uint256 paid = a0 - w.balance;
                assertEq(got, q.out, "lens buy");
                assertEq(paid, q.used, "lens used");
                if (pad.getLaunch(address(t)).graduated) break;
                // round trip of exactly what was bought never profits
                if ((r >> 160) % 2 == 0) {
                    p.set(dest, 0, 0, 0);
                    assertLe(_sell(w, t, got), paid, "round trip");
                }
            } else {
                uint256 amt = 1 + ((r >> 80) % bal);
                HookLensV2.Quote memory q = lens.quoteSell(address(t), amt, w);
                assertEq(_sell(w, t, amt), q.out, "lens sell");
            }
            _assertSolvent(t, cl);
        }
    }

    // ---------------------------------------------------------------- graduation

    function test_graduationBuyRunsModulesOnFilledPart() public {
        (CurveProbe p, uint32 pid) = _curveProbe(SWAP);
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (kothId, pid);
        (cfgs[0], cfgs[1]) = (_kothCfg(1 ether, 500, 100, 0, false), bytes(""));
        HookTokenV2 t = _launch(ids, cfgs, 100);
        p.set(address(p), 1_000, 1_000, 10_000); // 10% in, 10% out, 1% extra
        uint256 target = pad.getLaunch(address(t)).target;
        _buy(alice, t, target / 2);
        // one huge buy fills the rest: the modules see what the fill costs, not the whole input
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), target * 5, bob);
        uint256 b0 = bob.balance;
        uint256 got = _buy(bob, t, target * 5);
        HookLaunchpadV2.Launch memory l = pad.getLaunch(address(t));
        assertTrue(l.graduated, "graduated");
        uint256 paid = b0 - bob.balance;
        assertEq(paid, q.used, "lens used");
        assertEq(got, q.out, "lens out");
        assertLt(p.amountIn(), paid);
        assertLt(paid, target * 5);
        // modules' take was charged on top: modules saw `used`, bob paid used + grossed-up take
        assertEq(hook.claimable(address(p), NATIVE) - (target / 2) / 10, p.amountIn() / 10);
        assertEq(l.tokensSold, 800_000_000 ether);
        assertEq(t.balanceOf(address(pad)), 0);
        assertEq(address(pad).balance, pad.claimable(creator, address(0)) + pad.claimable(treasury, address(0)));
        (address king,,,) = koth.currentKing(address(t));
        assertEq(king, bob);
        // the pool then trades with the same modules
        p.set(address(p), 0, 0, 0);
        uint256 r = _routerBuy(carol, t, 1 ether);
        assertGt(r, 0);
        // curve credits stay plain balances; the pool's King fee (bob) is an ERC-6909 claim
        assertEq(hook.held(NATIVE), hook.claimable(address(p), NATIVE) + hook.claimable(alice, NATIVE));
        assertGt(hook.claimable(bob, NATIVE), 0);
        uint256 b1 = bob.balance;
        uint256 owed = hook.claimable(bob, NATIVE);
        vm.prank(bob);
        hook.claim(NATIVE, bob);
        assertEq(bob.balance - b1, owed);
    }

    function test_moduleSwapSpendsCurveCredits() public {
        (ProbeModule p, uint32 id) = _plainProbe(ModuleCaps.BEFORE_SWAP);
        HookTokenV2 t = _launch(_ids(id), _cfgs(""), 100);
        p.set(false, 1_000, 0);
        _buy(alice, t, 10 ether);
        assertEq(hook.claimable(address(p), NATIVE), 1 ether);
        assertEq(hook.held(NATIVE), 1 ether);
        p.set(false, 0, 0);
        PoolKey memory key = _graduate(t);
        uint256 dead0 = t.balanceOf(DEAD);
        (uint256 spent, uint256 out) = p.swapOwn(key, true, 1 ether, true);
        assertEq(spent, 1 ether);
        assertEq(t.balanceOf(DEAD) - dead0, out);
        assertEq(hook.held(NATIVE), 0);
        assertEq(hook.claimable(address(p), NATIVE), 0);
    }

    function _plainProbe(uint16 caps) internal returns (ProbeModule p, uint32 id) {
        p = new ProbeModule(address(hook), caps, 0);
        id = modules.addModule(address(p), '{"name":"probe"}');
    }

    function test_simulateCurveNeverPersists() public {
        (CurveProbe p, HookTokenV2 t) = _launchCurveProbe(SWAP);
        p.set(address(p), 1_000, 0, 0);
        AvaxHookV2.CurveTrade[] memory ts = new AvaxHookV2.CurveTrade[](1);
        ts[0] = AvaxHookV2.CurveTrade(address(t), address(0), bob, bob, true, true, 1 ether, 0, _spotSqrt(t), "");
        vm.prank(bob);
        vm.expectRevert();
        hook.simulateCurve(ts);
        assertEq(hook.claimable(address(p), NATIVE), 0);
        assertEq(hook.held(NATIVE), 0);
        assertEq(p.trader(), address(0));
    }

    function test_noSwapModulesSkipsHook() public {
        HookTokenV2 t = _launch(_ids(mpwId), _cfgs(_mpwCfg(5_000, 0)), 100);
        HookLensV2.Quote memory q = lens.quoteBuy(address(t), 1 ether, alice);
        assertEq(_buy(alice, t, 1 ether), q.out);
        assertEq(q.used, 1 ether);
    }

    // ---------------------------------------------------------------- gas and sizes

    function test_gasPerCurveTrade() public {
        HookTokenV2 t0 = _launch(new uint32[](0), new bytes[](0), 100);
        bytes[] memory c1 = _cfgs(_kothCfg(1 ether, 500, 50, 3600, false));
        HookTokenV2 t1 = _launch(_ids(kothId), c1, 100);
        (, uint32 probeId) = _plainProbe(ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER);
        uint32[] memory ids3 = new uint32[](3);
        bytes[] memory c3 = new bytes[](3);
        (ids3[0], ids3[1], ids3[2]) = (kothId, mpwId, probeId);
        (c3[0], c3[1], c3[2]) = (c1[0], _mpwCfg(5_000, 0), bytes(""));
        HookTokenV2 t3 = _launch(ids3, c3, 100);
        HookTokenV2[3] memory ts = [t0, t1, t3];
        uint256[3] memory n = [uint256(0), 1, 3];
        for (uint256 i; i < 3; ++i) {
            _buy(carol, ts[i], 3 ether); // a King to pay
            _coolAll(ts[i]);
            vm.prank(alice);
            uint256 g = gasleft();
            pad.buy{value: 1 ether}(address(ts[i]), 0);
            uint256 gBuy = g - gasleft();
            uint256 bal = ts[i].balanceOf(alice);
            _coolAll(ts[i]);
            vm.prank(alice);
            g = gasleft();
            pad.sell(address(ts[i]), bal, 0);
            uint256 gSell = g - gasleft();
            console2.log("modules / curve buy gas / curve sell gas", n[i], gBuy, gSell);
        }
    }

    function _coolAll(HookTokenV2 t) internal {
        address[6] memory a = [address(hook), address(pad), address(t), address(koth), address(mpw), alice];
        for (uint256 i; i < a.length; ++i) {
            vm.cool(a[i]);
        }
        (address[] memory mods,) = lens.modulesOf(address(t));
        for (uint256 i; i < mods.length; ++i) {
            vm.cool(mods[i]);
        }
    }

    function test_codeSizes() public view {
        console2.log("AvaxHookV2", address(hook).code.length);
        console2.log("HookLaunchpadV2", address(pad).code.length);
        console2.log("HookLensV2", address(lens).code.length);
        console2.log("AvaxHookRouterV2", address(router).code.length);
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(pad).code.length, 24_576);
        assertLe(address(lens).code.length, 24_576);
        assertLe(address(router).code.length, 24_576);
    }
}
