// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {SignedPriceFeed} from "../contracts/SignedPriceFeed.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";
import {HookTokenV2} from "../contracts/v2/HookTokenV2.sol";
import {AvaxHookRouterV2} from "../contracts/v2/AvaxHookRouterV2.sol";

/// Fork check that $HOOK works as a quote asset on the live v2 launchpad: allow it the way the Safe
/// batch will (`hooks-v2-ops.mjs quote-allow`), launch a HOOK-paired token, sell out the curve,
/// graduate into a HOOK pool, and sell back on the curve before that.
contract HookQuoteFork is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    address constant KEEPER = 0x2898F27E6db75C2b92363D4183e9F454060Fac3B;
    QuoteRegistry constant REGISTRY = QuoteRegistry(0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1);
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));
    address constant HOOK = 0x898D93e5BF6ee61a03f50CB0cdBF9C3751dA8Dc7;
    AvaxHookRouterV2 constant ROUTER = AvaxHookRouterV2(payable(0xC8B2b67A1E286f74648A705617d54a0415fc651a));

    function test_hookPairedLaunchGraduates() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        int256 price = 139904898355412; // $0.0001399, 18 decimals
        SignedPriceFeed feed = new SignedPriceFeed(SAFE, KEEPER, "HOOK / USD", 18, price);
        vm.startPrank(SAFE);
        REGISTRY.setPriceBounds(HOOK, uint128(uint256(price) / 10), uint128(uint256(price) * 10));
        REGISTRY.setQuote(HOOK, true, address(feed));
        vm.stopPrank();

        address creator = makeAddr("creator");
        address buyer = makeAddr("buyer");
        vm.deal(creator, 10 ether);
        deal(HOOK, buyer, 200_000_000 ether);

        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Hook Paired";
        a.symbol = "HPAIR";
        a.quote = HOOK;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3000});
        a.moduleIds = new uint32[](0);
        a.moduleConfigs = new bytes[](0);
        vm.prank(creator);
        address token = PAD.launch{value: PAD.creationFee()}(a);
        HookLaunchpadV2.Launch memory l = PAD.getLaunch(token);
        assertEq(l.quote, HOOK);

        vm.startPrank(buyer);
        IERC20(HOOK).approve(address(PAD), type(uint256).max);
        PAD.buyWithQuote(token, 1_000_000 ether, 0);
        uint256 got = IERC20(token).balanceOf(buyer);
        assertGt(got, 0);
        IERC20(token).approve(address(PAD), type(uint256).max);
        uint256 hookBefore = IERC20(HOOK).balanceOf(buyer);
        PAD.sell(token, got / 2, 0);
        assertGt(IERC20(HOOK).balanceOf(buyer), hookBefore);

        PAD.buyWithQuote{gas: 15_000_000}(token, 150_000_000 ether, 0);
        vm.stopPrank();
        l = PAD.getLaunch(token);
        assertTrue(l.complete, "curve complete");
        assertTrue(l.graduated, "graduated");
        assertGt(IERC20(HOOK).balanceOf(buyer), 0, "excess HOOK refunded");
    }

    /// "Pay with AVAX" on a HOOK-paired curve, as the trade panel runs it: AVAX -> HOOK through the
    /// AvaxHook router (HOOK's own pool), then the curve; selling goes back the same way.
    function test_payWithAvaxThroughHookPool() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        (bool allowed,,) = REGISTRY.quotes(HOOK);
        if (!allowed) {
            SignedPriceFeed feed = new SignedPriceFeed(SAFE, KEEPER, "HOOK / USD", 18, 139904898355412);
            vm.startPrank(SAFE);
            REGISTRY.setPriceBounds(HOOK, 13990489835541, 1399048983554120);
            REGISTRY.setQuote(HOOK, true, address(feed));
            vm.stopPrank();
        }
        address creator = makeAddr("creator");
        address trader = makeAddr("trader");
        vm.deal(creator, 10 ether);
        vm.deal(trader, 10 ether);

        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Hook Paired";
        a.symbol = "HPAIR";
        a.quote = HOOK;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3000});
        a.moduleIds = new uint32[](0);
        a.moduleConfigs = new bytes[](0);
        vm.prank(creator);
        address token = PAD.launch{value: PAD.creationFee()}(a);

        vm.startPrank(trader);
        uint256 hookGot = ROUTER.buy{value: 1 ether}(HOOK, 1 ether, 0, address(0), block.timestamp + 600, "");
        assertEq(IERC20(HOOK).balanceOf(trader), hookGot);
        assertGt(hookGot, 80_000 ether, "1 AVAX buys ~90k HOOK in its own pool");
        IERC20(HOOK).approve(address(PAD), hookGot);
        PAD.buyWithData(token, hookGot, 1, address(0), "");
        uint256 tokens = IERC20(token).balanceOf(trader);
        assertGt(tokens, 0);
        assertEq(IERC20(HOOK).balanceOf(trader), 0);

        PAD.sellWithData(token, tokens, 1, "");
        uint256 hookBack = IERC20(HOOK).balanceOf(trader);
        assertGt(hookBack, 0);
        IERC20(HOOK).approve(address(ROUTER), hookBack);
        uint256 avaxBefore = trader.balance;
        uint256 avaxOut = ROUTER.sell(HOOK, hookBack, 1, block.timestamp + 600, "");
        assertEq(trader.balance - avaxBefore, avaxOut);
        emit log_named_decimal_uint("HOOK per 1 AVAX", hookGot, 18);
        emit log_named_decimal_uint("AVAX back after the round trip", avaxOut, 18);
        vm.stopPrank();
    }
}
