// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {SignedPriceFeed} from "../contracts/SignedPriceFeed.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";

/// Fork check that the C-Chain tokens of Avalanche L1s (BEAM, BLAZE, GUN, NXPC) work as quote assets on the
/// live v2 launchpad: allow each the way the Safe batch will (`hooks-v2-ops.mjs quote-allow`), launch a
/// paired token, buy and sell on the curve, then sell out the curve and graduate into a v4 pool.
contract L1QuoteFork is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    address constant KEEPER = 0x2898F27E6db75C2b92363D4183e9F454060Fac3B;
    QuoteRegistry constant REGISTRY = QuoteRegistry(0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1);
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));

    address constant BEAM = 0x62D0A8458eD7719FDAF978fe5929C6D342B0bFcE;
    address constant BLAZE = 0x297731Eb3CAB3834525fc9Ea061fd71d8f4645C9;
    address constant GUN = 0x26deBD39D5eD069770406FCa10A0E4f8d2c743eB;
    address constant NXPC = 0x5E0E90E268BC247Cc850c789A0DB0d5c7621fb59;

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
    }

    // USD prices (18 decimals) as of 2026-10-12, GeckoTerminal.
    function test_beam() public {
        _launchAndGraduate(BEAM, 2_669_933_144_622_150);
    }

    function test_blaze() public {
        _launchAndGraduate(BLAZE, 486_770_039_861_641);
    }

    function test_gun() public {
        _launchAndGraduate(GUN, 2_827_336_921_518_700);
    }

    function test_nxpc() public {
        _launchAndGraduate(NXPC, 217_571_438_237_408_000);
    }

    function _launchAndGraduate(address quote, int256 price) internal {
        SignedPriceFeed feed = new SignedPriceFeed(SAFE, KEEPER, "L1 / USD", 18, price);
        vm.startPrank(SAFE);
        REGISTRY.setPriceBounds(quote, uint128(uint256(price) / 10), uint128(uint256(price) * 10));
        REGISTRY.setQuote(quote, true, address(feed));
        vm.stopPrank();

        address creator = makeAddr("creator");
        address buyer = makeAddr("buyer");
        vm.deal(creator, 10 ether);
        // $200k of the quote: more than any curve needs to graduate.
        uint256 budget = (200_000 ether * 1e18) / uint256(price);
        deal(quote, buyer, budget);
        assertEq(IERC20(quote).balanceOf(buyer), budget, "deal");

        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "L1 Paired";
        a.symbol = "L1P";
        a.quote = quote;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3000});
        a.moduleIds = new uint32[](0);
        a.moduleConfigs = new bytes[](0);
        vm.prank(creator);
        address token = PAD.launch{value: PAD.creationFee()}(a);
        assertEq(PAD.getLaunch(token).quote, quote);

        vm.startPrank(buyer);
        IERC20(quote).approve(address(PAD), type(uint256).max);
        // $100 buy, then sell half back.
        PAD.buyWithQuote(token, (100 ether * 1e18) / uint256(price), 0);
        uint256 got = IERC20(token).balanceOf(buyer);
        assertGt(got, 0, "bought");
        IERC20(token).approve(address(PAD), type(uint256).max);
        uint256 before = IERC20(quote).balanceOf(buyer);
        PAD.sell(token, got / 2, 0);
        assertGt(IERC20(quote).balanceOf(buyer), before, "sold");

        uint256 spentBefore = IERC20(quote).balanceOf(buyer);
        PAD.buyWithQuote{gas: 15_000_000}(token, spentBefore, 0);
        vm.stopPrank();
        HookLaunchpadV2.Launch memory l = PAD.getLaunch(token);
        assertTrue(l.complete, "curve complete");
        assertTrue(l.graduated, "graduated");
        uint256 spent = spentBefore - IERC20(quote).balanceOf(buyer);
        emit log_named_decimal_uint("quote spent to graduate", spent, 18);
        emit log_named_decimal_uint("  in USD", (spent * uint256(price)) / 1e18, 18);
        // Nothing stuck in the launchpad beyond what it books (no fee-on-transfer surprises).
        assertGt(IERC20(quote).balanceOf(buyer), 0, "excess refunded");
    }
}
