// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {SignedPriceHub, HubPriceFeed} from "../contracts/SignedPriceHub.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";

/// Fork check of the 2026-11 mStock quotes on the live v3 launchpad through a SignedPriceHub: the Safe creates
/// the clone feeds and allows the quotes (as script/hub-ops.mjs will), a launch paired with mPLTR trades on its
/// curve, goes stale after 26 h like any feed, is refreshed by a signed update through the clone (the launch
/// form's path) and by a keeper batch, then sells out and graduates.
contract SignedPriceHubFork is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    QuoteRegistry constant REGISTRY = QuoteRegistry(0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1);
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0xD4C28ec86DAA5227ce6548d42D2DEb890d3C99E1));

    address constant mPLTR = 0x3D82C029489c8232cF9005ddDF5c6cCe1b99Af1B;
    address constant mGME = 0xC9745586C8772641499b5eE7239d121648f7701D;
    address constant mSPCX = 0x1942B3F2AC31174d68Dff07c8756690Fa79476Ab;

    bytes32 constant TYPEHASH = keccak256("PriceUpdate(int256 answer,uint64 timestamp)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 constant SIGNER_KEY = 0x51D3;

    SignedPriceHub hub;
    HubPriceFeed fPLTR;
    HubPriceFeed fGME;
    HubPriceFeed fSPCX;

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://avalanche-c-chain-rpc.publicnode.com")));
        hub = new SignedPriceHub(SAFE, vm.addr(SIGNER_KEY));
        vm.startPrank(SAFE);
        fPLTR = _allow(mPLTR, "mPLTR / USD", 173.7e18);
        fGME = _allow(mGME, "mGME / USD", 25.1e18);
        fSPCX = _allow(mSPCX, "mSPCX / USD", 140e18);
        vm.stopPrank();
    }

    function _allow(address token, string memory desc, int256 price) internal returns (HubPriceFeed f) {
        f = HubPriceFeed(hub.createFeed(desc, price));
        REGISTRY.setPriceBounds(token, uint128(uint256(price) / 4), uint128(uint256(price) * 4));
        REGISTRY.setQuote(token, true, address(f));
    }

    function _sign(address feed, int256 answer, uint64 ts) internal view returns (bytes memory) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("AvaxHook SignedPriceFeed"), keccak256("1"), block.chainid, feed));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(TYPEHASH, answer, ts))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _launch(address quote, address creator) internal returns (address token) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Stock Paired";
        a.symbol = "STKP";
        a.quote = quote;
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 3000});
        a.moduleIds = new uint32[](0);
        a.moduleConfigs = new bytes[](0);
        vm.deal(creator, 10 ether);
        uint256 fee = PAD.creationFee();
        vm.prank(creator);
        token = PAD.launch{value: fee}(a);
    }

    function test_registryPricesTheNewStocks() public view {
        assertEq(REGISTRY.usdPrice(mPLTR), 173.7e18);
        assertEq(REGISTRY.usdPrice(mGME), 25.1e18);
        assertEq(REGISTRY.usdPrice(mSPCX), 140e18);
        (bool allowed,, address feed) = REGISTRY.quotes(mPLTR);
        assertTrue(allowed);
        assertEq(feed, address(fPLTR));
        // $2,500 start FDV in mPLTR
        QuoteRegistry.CurveParams memory p = REGISTRY.curveParams(mPLTR);
        assertEq(p.quoteUsd, 173.7e18);
        assertGt(p.target, 0);
    }

    function test_launchTradeStaleRefreshGraduate() public {
        uint256 t0 = vm.getBlockTimestamp();
        address token = _launch(mPLTR, makeAddr("creator"));
        assertEq(PAD.getLaunch(token).quote, mPLTR);

        address buyer = makeAddr("buyer");
        uint256 budget = uint256(200_000 ether) * 1e18 / uint256(173.7e18); // $200k of mPLTR, more than a curve needs
        deal(mPLTR, buyer, budget);
        vm.startPrank(buyer);
        IERC20(mPLTR).approve(address(PAD), type(uint256).max);
        PAD.buyWithQuote(token, uint256(100 ether) * 1e18 / uint256(173.7e18), 0); // $100
        uint256 got = IERC20(token).balanceOf(buyer);
        assertGt(got, 0, "bought");
        IERC20(token).approve(address(PAD), type(uint256).max);
        uint256 before = IERC20(mPLTR).balanceOf(buyer);
        PAD.sell(token, got / 2, 0);
        assertGt(IERC20(mPLTR).balanceOf(buyer), before, "sold");
        vm.stopPrank();

        // 27 h later the hub price is stale: the registry refuses it, so a new mPLTR launch reverts …
        vm.warp(t0 + 27 hours);
        vm.expectRevert(QuoteRegistry.StalePrice.selector);
        REGISTRY.usdPrice(mPLTR);
        vm.expectRevert();
        this.launchExternal(mPLTR);
        // … while trading the existing curve keeps working
        vm.prank(buyer);
        PAD.buyWithQuote(token, uint256(10 ether) * 1e18 / uint256(173.7e18), 0);

        // the launch form's refresh: a signed update sent to the clone
        uint64 ts = uint64(t0 + 27 hours);
        fPLTR.update(180e18, ts, _sign(address(fPLTR), 180e18, ts));
        assertEq(REGISTRY.usdPrice(mPLTR), 180e18);
        address token2 = _launch(mPLTR, makeAddr("creator2"));
        assertEq(PAD.getLaunch(token2).quote, mPLTR);

        // the keeper's refresh: one batch for all three feeds (mPLTR already fresh at ts → skipped)
        vm.warp(t0 + 27 hours + 60);
        uint64 ts2 = uint64(t0 + 27 hours + 60);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](3);
        u[0] = SignedPriceHub.Update(address(fPLTR), 181e18, ts, _sign(address(fPLTR), 181e18, ts));
        u[1] = SignedPriceHub.Update(address(fGME), 26e18, ts2, _sign(address(fGME), 26e18, ts2));
        u[2] = SignedPriceHub.Update(address(fSPCX), 141e18, ts2, _sign(address(fSPCX), 141e18, ts2));
        assertEq(hub.updateBatch(u), 2);
        assertEq(REGISTRY.usdPrice(mPLTR), 180e18, "not-newer entry skipped");
        assertEq(REGISTRY.usdPrice(mGME), 26e18);
        assertEq(REGISTRY.usdPrice(mSPCX), 141e18);

        // sell out the first curve and graduate into its v4 pool
        uint256 left = IERC20(mPLTR).balanceOf(buyer);
        vm.prank(buyer);
        PAD.buyWithQuote{gas: 15_000_000}(token, left, 0);
        HookLaunchpadV2.Launch memory l = PAD.getLaunch(token);
        assertTrue(l.complete, "curve complete");
        assertTrue(l.graduated, "graduated");
        uint256 spent = left - IERC20(mPLTR).balanceOf(buyer);
        emit log_named_decimal_uint("mPLTR spent to graduate", spent, 18);
    }

    function launchExternal(address quote) external returns (address) {
        return _launch(quote, makeAddr("creator3"));
    }

    function test_lensListsTheNewQuotes() public view {
        address[] memory qs = new address[](REGISTRY.quoteCount());
        for (uint256 i; i < qs.length; ++i) qs[i] = REGISTRY.quoteList(i);
        bool p;
        bool g;
        for (uint256 i; i < qs.length; ++i) {
            if (qs[i] == mPLTR) p = true;
            if (qs[i] == mGME) g = true;
        }
        assertTrue(p && g, "listed");
    }
}
