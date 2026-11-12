// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignedPriceHub, HubPriceFeed} from "../contracts/SignedPriceHub.sol";
import {SignedPriceFeed} from "../contracts/SignedPriceFeed.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";

contract HubCoin is ERC20 {
    constructor() ERC20("Stock", "mSTK") {}
}

contract SignedPriceHubTest is Test {
    bytes32 constant TYPEHASH = keccak256("PriceUpdate(int256 answer,uint64 timestamp)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint256 signerKey = 0xA11CE;
    address signerAddr;
    address owner = makeAddr("safe");
    SignedPriceHub hub;
    HubPriceFeed feedA;
    HubPriceFeed feedB;

    function setUp() public {
        vm.warp(1_700_000_000);
        signerAddr = vm.addr(signerKey);
        hub = new SignedPriceHub(owner, signerAddr);
        vm.startPrank(owner);
        feedA = HubPriceFeed(hub.createFeed("mAAA / USD", 100e18));
        feedB = HubPriceFeed(hub.createFeed("mBBB / USD", 50e18));
        vm.stopPrank();
    }

    /// Exactly what keeper/price-signer.mjs signs (viem signTypedData, domain verifyingContract = feed).
    function _sign(address feed, uint256 key, int256 answer, uint64 ts, uint256 chainId) internal pure returns (bytes memory) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("AvaxHook SignedPriceFeed"), keccak256("1"), chainId, feed));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(TYPEHASH, answer, ts))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign(address feed, int256 answer, uint64 ts) internal view returns (bytes memory) {
        return _sign(feed, signerKey, answer, ts, block.chainid);
    }

    function _answer(HubPriceFeed f) internal view returns (int256 a, uint256 u, uint80 round) {
        (round, a,, u,) = f.latestRoundData();
    }

    // ---------------------------------------------------------------- setup / views

    function test_initialState() public view {
        assertEq(hub.owner(), owner);
        assertEq(hub.signer(), signerAddr);
        assertEq(hub.feedCount(), 2);
        assertEq(hub.feeds(0), address(feedA));
        assertEq(hub.feeds(1), address(feedB));
        assertTrue(hub.isFeed(address(feedA)));
        assertFalse(hub.isFeed(hub.feedImplementation()));
        assertEq(hub.MAX_SIGNATURE_AGE(), 10 minutes);

        (uint80 round, int256 a, uint256 s, uint256 u, uint80 ar) = feedA.latestRoundData();
        assertEq(round, 1);
        assertEq(ar, 1);
        assertEq(a, 100e18);
        assertEq(s, block.timestamp);
        assertEq(u, block.timestamp);
        assertEq(feedA.decimals(), 18);
        assertEq(feedA.description(), "mAAA / USD");
        assertEq(feedB.description(), "mBBB / USD");
        assertEq(address(feedA.hub()), address(hub));
        assertEq(feedA.signer(), signerAddr);
        assertEq(feedA.owner(), owner);
        // a clone is tiny (EIP-1167): 45 bytes
        assertEq(address(feedA).code.length, 45);
    }

    function test_createFeed_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.createFeed("x", 1e18);
    }

    function test_createFeed_rejectsBadInitial() public {
        vm.startPrank(owner);
        vm.expectRevert(SignedPriceHub.BadPrice.selector);
        hub.createFeed("x", 0);
        vm.expectRevert(SignedPriceHub.BadPrice.selector);
        hub.createFeed("x", -1);
        vm.stopPrank();
    }

    function test_createFeed_emits() public {
        vm.prank(owner);
        vm.recordLogs();
        address f = hub.createFeed("mCCC / USD", 7e18);
        assertTrue(hub.isFeed(f));
        assertEq(hub.feedCount(), 3);
        assertEq(HubPriceFeed(f).description(), "mCCC / USD");
    }

    // ---------------------------------------------------------------- clone initialisation

    function test_clone_cannotBeReinitialized() public {
        vm.expectRevert(HubPriceFeed.InitializeDenied.selector);
        feedA.initialize("hijack");
        vm.prank(address(hub));
        vm.expectRevert(HubPriceFeed.InitializeDenied.selector);
        feedA.initialize("hijack");
        assertEq(feedA.description(), "mAAA / USD");
    }

    function test_implementation_cannotBeInitialized() public {
        HubPriceFeed impl = HubPriceFeed(hub.feedImplementation());
        vm.expectRevert(HubPriceFeed.InitializeDenied.selector);
        impl.initialize("x");
        vm.prank(address(hub));
        vm.expectRevert(HubPriceFeed.InitializeDenied.selector);
        impl.initialize("x");
    }

    function test_implementation_isNotAFeed() public {
        address impl = hub.feedImplementation();
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(impl, 1e18, ts);
        vm.expectRevert(SignedPriceHub.UnknownFeed.selector);
        hub.update(impl, 1e18, ts, sig);
    }

    // ---------------------------------------------------------------- update

    function test_update_throughClone_anyoneSubmits() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp - 5);
        bytes memory sig = _sign(address(feedA), 120e18, ts);
        vm.expectEmit(address(hub));
        emit SignedPriceHub.PriceSet(address(feedA), 120e18, ts);
        vm.prank(makeAddr("user"));
        feedA.update(120e18, ts, sig);
        (int256 a, uint256 u, uint80 round) = _answer(feedA);
        assertEq(a, 120e18);
        assertEq(u, ts);
        assertEq(round, 2);
        (int256 b,,) = _answer(feedB);
        assertEq(b, 50e18, "other feed untouched");
    }

    function test_update_directOnHub() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        hub.update(address(feedB), 55e18, ts, _sign(address(feedB), 55e18, ts));
        (int256 b,,) = _answer(feedB);
        assertEq(b, 55e18);
    }

    function test_signatureForOneFeed_doesNotFitAnother() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sigA = _sign(address(feedA), 1e18, ts);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedB.update(1e18, ts, sigA);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        hub.update(address(feedB), 1e18, ts, sigA);
    }

    function test_signatureForOtherChain_rejected() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(feedA), signerKey, 1e18, ts, block.chainid + 1);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, sig);
    }

    function test_signatureForStandaloneFeedAddress_rejected() public {
        // a SignedPriceFeed signature for some other address can't be pointed at a hub feed
        SignedPriceFeed other = new SignedPriceFeed(owner, signerAddr, "x", 18, 1e18);
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(other), 2e18, ts);
        other.update(2e18, ts, sig); // valid there
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(2e18, ts, sig);
    }

    function test_replay_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(feedA), 3e18, ts);
        feedA.update(3e18, ts, sig);
        vm.expectRevert(SignedPriceHub.NotNewer.selector);
        feedA.update(3e18, ts, sig);
    }

    function test_rollback_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 newer = uint64(block.timestamp);
        uint64 older = newer - 10;
        bytes memory sigOld = _sign(address(feedA), 1e18, older);
        feedA.update(5e18, newer, _sign(address(feedA), 5e18, newer));
        vm.expectRevert(SignedPriceHub.NotNewer.selector);
        feedA.update(1e18, older, sigOld);
    }

    function test_sameTimestampAsCreation_reverts() public {
        uint64 ts = uint64(block.timestamp); // createFeed dated now
        vm.expectRevert(SignedPriceHub.NotNewer.selector);
        feedA.update(1e18, ts, _sign(address(feedA), 1e18, ts));
    }

    function test_staleSignature_reverts() public {
        vm.warp(block.timestamp + 1 hours);
        uint64 ts = uint64(block.timestamp - 10 minutes - 1);
        bytes memory sig = _sign(address(feedA), 1e18, ts);
        vm.expectRevert(SignedPriceHub.StaleSignature.selector);
        feedA.update(1e18, ts, sig);
        // exactly MAX_SIGNATURE_AGE old is still fine
        uint64 edge = uint64(block.timestamp - 10 minutes);
        feedA.update(1e18, edge, _sign(address(feedA), 1e18, edge));
    }

    function test_futureTimestamp_reverts() public {
        uint64 ts = uint64(block.timestamp + 1);
        bytes memory sig = _sign(address(feedA), 1e18, ts);
        vm.expectRevert(SignedPriceHub.FutureTimestamp.selector);
        feedA.update(1e18, ts, sig);
    }

    function test_badPrice_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        vm.expectRevert(SignedPriceHub.BadPrice.selector);
        feedA.update(0, ts, _sign(address(feedA), 0, ts));
        vm.expectRevert(SignedPriceHub.BadPrice.selector);
        feedA.update(-5, ts, _sign(address(feedA), -5, ts));
    }

    function test_wrongSigner_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(feedA), 0xB0B, 1e18, ts, block.chainid);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, sig);
    }

    function test_tamperedAnswer_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(feedA), 1e18, ts);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(2e18, ts, sig);
    }

    function test_malformedSignature_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, hex"1234");
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, new bytes(65));
    }

    function test_highS_malleatedSignature_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(feedA), 1e18, ts);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        bytes memory flipped = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, flipped);
    }

    // ---------------------------------------------------------------- batch

    function _upd(HubPriceFeed f, int256 a, uint64 ts) internal view returns (SignedPriceHub.Update memory) {
        return SignedPriceHub.Update(address(f), a, ts, _sign(address(f), a, ts));
    }

    function test_batch_appliesAll() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](2);
        u[0] = _upd(feedA, 101e18, ts);
        u[1] = _upd(feedB, 51e18, ts);
        vm.prank(makeAddr("keeper"));
        assertEq(hub.updateBatch(u), 2);
        (int256 a,,) = _answer(feedA);
        (int256 b,,) = _answer(feedB);
        assertEq(a, 101e18);
        assertEq(b, 51e18);
    }

    function test_batch_skipsNotNewer() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        // a user refreshed feedA first with the same signed price
        SignedPriceHub.Update memory a = _upd(feedA, 101e18, ts);
        feedA.update(a.answer, a.timestamp, a.signature);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](2);
        u[0] = a;
        u[1] = _upd(feedB, 51e18, ts);
        assertEq(hub.updateBatch(u), 1);
        (, , uint80 roundA) = _answer(feedA);
        assertEq(roundA, 2, "feedA applied once");
        (int256 b,,) = _answer(feedB);
        assertEq(b, 51e18);
    }

    function test_batch_duplicateEntry_appliedOnce() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](2);
        u[0] = _upd(feedA, 101e18, ts);
        u[1] = u[0];
        assertEq(hub.updateBatch(u), 1);
    }

    function test_batch_badSignature_revertsAll() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](2);
        u[0] = _upd(feedA, 101e18, ts);
        u[1] = SignedPriceHub.Update(address(feedB), 51e18, ts, _sign(address(feedA), 51e18, ts));
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        hub.updateBatch(u);
        (int256 a,,) = _answer(feedA);
        assertEq(a, 100e18, "nothing applied");
    }

    function test_batch_unknownFeed_reverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](1);
        address bogus = makeAddr("bogus");
        u[0] = SignedPriceHub.Update(bogus, 1e18, ts, _sign(bogus, 1e18, ts));
        vm.expectRevert(SignedPriceHub.UnknownFeed.selector);
        hub.updateBatch(u);
    }

    function test_batch_empty() public {
        assertEq(hub.updateBatch(new SignedPriceHub.Update[](0)), 0);
    }

    function test_batch_staleOrFuture_reverts() public {
        vm.warp(block.timestamp + 1 hours);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](1);
        u[0] = _upd(feedA, 1e18, uint64(block.timestamp - 11 minutes));
        vm.expectRevert(SignedPriceHub.StaleSignature.selector);
        hub.updateBatch(u);
        u[0] = _upd(feedA, 1e18, uint64(block.timestamp + 1));
        vm.expectRevert(SignedPriceHub.FutureTimestamp.selector);
        hub.updateBatch(u);
    }

    // ---------------------------------------------------------------- owner controls

    function test_forcePrice() public {
        vm.warp(block.timestamp + 50);
        vm.prank(owner);
        hub.forcePrice(address(feedA), 9e18);
        (int256 a, uint256 u, uint80 round) = _answer(feedA);
        assertEq(a, 9e18);
        assertEq(u, block.timestamp);
        assertEq(round, 2);
    }

    function test_forcePrice_guards() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.forcePrice(address(feedA), 1e18);
        vm.startPrank(owner);
        vm.expectRevert(SignedPriceHub.UnknownFeed.selector);
        hub.forcePrice(makeAddr("bogus"), 1e18);
        vm.expectRevert(SignedPriceHub.BadPrice.selector);
        hub.forcePrice(address(feedA), 0);
        vm.stopPrank();
    }

    function test_setSigner_rotates() public {
        uint256 newKey = 0xC0FFEE;
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setSigner(vm.addr(newKey));
        vm.prank(owner);
        hub.setSigner(vm.addr(newKey));
        assertEq(feedA.signer(), vm.addr(newKey));
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory oldSig = _sign(address(feedA), 1e18, ts);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, oldSig);
        feedA.update(1e18, ts, _sign(address(feedA), newKey, 1e18, ts, block.chainid));
    }

    function test_ownership_twoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        hub.transferOwnership(next);
        assertEq(hub.owner(), owner);
        vm.prank(next);
        hub.acceptOwnership();
        assertEq(hub.owner(), next);
        assertEq(feedA.owner(), next);
    }

    // ---------------------------------------------------------------- QuoteRegistry integration

    function test_registry_readsCloneLikeAFeed() public {
        QuoteRegistry reg = new QuoteRegistry(owner);
        HubCoin coin = new HubCoin();
        vm.startPrank(owner);
        reg.setQuote(address(coin), true, address(feedA));
        reg.setPriceBounds(address(coin), 25e18, 400e18);
        vm.stopPrank();
        assertEq(reg.usdPrice(address(coin)), 100e18);
        QuoteRegistry.CurveParams memory p = reg.curveParams(address(coin));
        assertEq(p.quoteUsd, 100e18);
        // $2,500 start FDV at $100/coin: x0 = 25 coin · y0 / 1B
        assertApproxEqRel(uint256(p.virtualQuote) * 1e27 / p.virtualTokens, 25e18 * 1e27 / 1e27, 1e12);

        // goes stale after 26 h like any feed …
        vm.warp(block.timestamp + 26 hours + 1);
        vm.expectRevert(QuoteRegistry.StalePrice.selector);
        reg.usdPrice(address(coin));
        // … and a signed refresh through the clone brings it back
        uint64 ts = uint64(block.timestamp);
        feedA.update(110e18, ts, _sign(address(feedA), 110e18, ts));
        assertEq(reg.usdPrice(address(coin)), 110e18);

        // bounds still apply
        vm.prank(owner);
        hub.forcePrice(address(feedA), 500e18);
        vm.expectRevert(QuoteRegistry.PriceOutOfBounds.selector);
        reg.usdPrice(address(coin));
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_update(int256 answer, uint64 age, uint64 ahead) public {
        vm.warp(block.timestamp + 1 days);
        age = uint64(bound(age, 0, 2 hours));
        ahead = uint64(bound(ahead, 0, 1 hours));
        uint64 ts = uint64(block.timestamp) - age + (age == 0 ? ahead : 0);
        bytes memory sig = _sign(address(feedA), answer, ts);
        bool ok = answer > 0 && ts <= block.timestamp && uint256(ts) + 10 minutes >= block.timestamp;
        if (!ok) vm.expectRevert();
        feedA.update(answer, ts, sig);
        if (ok) {
            (int256 a, uint256 u,) = _answer(feedA);
            assertEq(a, answer);
            assertEq(u, ts);
        }
    }

    function testFuzz_otherKeyNeverAccepted(uint256 key) public {
        key = bound(key, 1, SECP256K1_N - 1);
        vm.assume(key != signerKey);
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(address(feedA), key, 1e18, ts, block.chainid);
        vm.expectRevert(SignedPriceHub.BadSignature.selector);
        feedA.update(1e18, ts, sig);
    }

    // ---------------------------------------------------------------- gas: 8 single updates vs one batch

    function test_gas_batchVsSingles() public {
        vm.startPrank(owner);
        HubPriceFeed[] memory fs = new HubPriceFeed[](8);
        for (uint256 i; i < 8; ++i) fs[i] = HubPriceFeed(hub.createFeed("f", 1e18));
        vm.stopPrank();
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 100);
        uint64 ts = uint64(t0 + 100);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](8);
        for (uint256 i; i < 8; ++i) u[i] = _upd(fs[i], 2e18, ts);
        uint256 g = gasleft();
        hub.updateBatch(u);
        uint256 batchGas = g - gasleft();
        emit log_named_uint("batch of 8 (execution gas)", batchGas);

        vm.warp(t0 + 200); // via_ir caches block.timestamp within a test, so keep explicit times
        ts = uint64(t0 + 200);
        uint256 singles;
        for (uint256 i; i < 8; ++i) {
            SignedPriceHub.Update memory x = _upd(fs[i], 3e18, ts);
            g = gasleft();
            fs[i].update(x.answer, x.timestamp, x.signature);
            singles += g - gasleft() + 21_000; // each single is its own transaction
        }
        emit log_named_uint("8 single txs (execution + 21k base each)", singles);
        assertLt(batchGas + 21_000, singles);
    }
}
