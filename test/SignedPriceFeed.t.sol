// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignedPriceFeed} from "../contracts/SignedPriceFeed.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";

contract MockCoin is ERC20 {
    constructor() ERC20("Coin", "COIN") {}
}

contract SignedPriceFeedTest is Test {
    bytes32 constant TYPEHASH = keccak256("PriceUpdate(int256 answer,uint64 timestamp)");
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256 signerKey = 0xA11CE;
    address signerAddr;
    address owner = makeAddr("owner");
    SignedPriceFeed feed;

    function setUp() public {
        vm.warp(1_700_000_000);
        signerAddr = vm.addr(signerKey);
        feed = new SignedPriceFeed(owner, signerAddr, "COIN / USD", 18, 2e18);
    }

    function _sign(SignedPriceFeed f, uint256 key, int256 answer, uint64 ts, uint256 chainId)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("AvaxHook SignedPriceFeed"), keccak256("1"), chainId, address(f)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(TYPEHASH, answer, ts))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign(int256 answer, uint64 ts) internal view returns (bytes memory) {
        return _sign(feed, signerKey, answer, ts, block.chainid);
    }

    function test_initialState() public view {
        (uint80 round, int256 a, uint256 s, uint256 u, uint80 ar) = feed.latestRoundData();
        assertEq(round, 1);
        assertEq(ar, 1);
        assertEq(a, 2e18);
        assertEq(s, block.timestamp);
        assertEq(u, block.timestamp);
        assertEq(feed.decimals(), 18);
        assertEq(feed.description(), "COIN / USD");
        assertEq(feed.signer(), signerAddr);
        assertEq(feed.owner(), owner);
        assertEq(feed.MAX_SIGNATURE_AGE(), 10 minutes);
    }

    function test_validUpdate_anyoneSubmits() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp - 5);
        bytes memory sig = _sign(3e18, ts);
        vm.expectEmit(address(feed));
        emit SignedPriceFeed.PriceSet(3e18, ts);
        vm.prank(makeAddr("randomUser"));
        feed.update(3e18, ts, sig);
        (uint80 round, int256 a,, uint256 u,) = feed.latestRoundData();
        assertEq(round, 2);
        assertEq(a, 3e18);
        assertEq(u, ts);
    }

    function test_replayReverts() public {
        vm.warp(block.timestamp + 100);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(3e18, ts);
        feed.update(3e18, ts, sig);
        vm.expectRevert(SignedPriceFeed.NotNewer.selector);
        feed.update(3e18, ts, sig);
    }

    function test_rollbackReverts() public {
        vm.warp(block.timestamp + 100);
        uint64 older = uint64(block.timestamp - 50);
        bytes memory oldSig = _sign(1e18, older);
        uint64 newer = uint64(block.timestamp - 10);
        feed.update(3e18, newer, _sign(3e18, newer));
        vm.expectRevert(SignedPriceFeed.NotNewer.selector);
        feed.update(1e18, older, oldSig);
    }

    function test_staleSignatureReverts() public {
        vm.warp(block.timestamp + 1 hours);
        uint64 ts = uint64(block.timestamp - 10 minutes - 1);
        bytes memory sig = _sign(3e18, ts);
        vm.expectRevert(SignedPriceFeed.StaleSignature.selector);
        feed.update(3e18, ts, sig);
        // exactly 10 minutes old is still accepted
        ts = uint64(block.timestamp - 10 minutes);
        feed.update(3e18, ts, _sign(3e18, ts));
    }

    function test_futureTimestampReverts() public {
        vm.warp(block.timestamp + 10);
        // even 1s ahead is refused: QuoteRegistry would reject that price until the chain caught up
        uint64 ts = uint64(block.timestamp + 1);
        bytes memory sig = _sign(3e18, ts);
        vm.expectRevert(SignedPriceFeed.FutureTimestamp.selector);
        feed.update(3e18, ts, sig);
        ts = uint64(block.timestamp);
        feed.update(3e18, ts, _sign(3e18, ts));
        (,, , uint256 updatedAt,) = feed.latestRoundData();
        assertLe(updatedAt, block.timestamp);
    }

    function test_badPriceReverts() public {
        vm.warp(block.timestamp + 10);
        uint64 ts = uint64(block.timestamp);
        vm.expectRevert(SignedPriceFeed.BadPrice.selector);
        feed.update(0, ts, _sign(0, ts));
        vm.expectRevert(SignedPriceFeed.BadPrice.selector);
        feed.update(-1, ts, _sign(-1, ts));
    }

    function test_wrongSignerReverts() public {
        vm.warp(block.timestamp + 10);
        uint64 ts = uint64(block.timestamp);
        bytes memory sig = _sign(feed, 0xB0B, 3e18, ts, block.chainid);
        vm.expectRevert(SignedPriceFeed.BadSignature.selector);
        feed.update(3e18, ts, sig);
        // tampered answer
        sig = _sign(3e18, ts);
        vm.expectRevert(SignedPriceFeed.BadSignature.selector);
        feed.update(4e18, ts, sig);
        // garbage signature
        vm.expectRevert(SignedPriceFeed.BadSignature.selector);
        feed.update(3e18, ts, hex"1234");
    }

    function test_signatureForOtherFeedOrChainReverts() public {
        SignedPriceFeed other = new SignedPriceFeed(owner, signerAddr, "OTHER / USD", 18, 2e18);
        vm.warp(block.timestamp + 10);
        uint64 ts = uint64(block.timestamp);
        bytes memory sigA = _sign(feed, signerKey, 3e18, ts, block.chainid);
        vm.expectRevert(SignedPriceFeed.BadSignature.selector);
        other.update(3e18, ts, sigA);
        feed.update(3e18, ts, sigA);

        bytes memory wrongChain = _sign(other, signerKey, 3e18, ts, block.chainid + 1);
        vm.expectRevert(SignedPriceFeed.BadSignature.selector);
        other.update(3e18, ts, wrongChain);
        // the same signature becomes valid only on the chain it was signed for
        vm.chainId(block.chainid + 1);
        other.update(3e18, ts, wrongChain);
    }

    function test_forcePriceAuth() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        feed.forcePrice(5e18);
        vm.prank(signerAddr);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, signerAddr));
        feed.forcePrice(5e18);
        vm.warp(block.timestamp + 50);
        vm.prank(owner);
        feed.forcePrice(5e18);
        (, int256 a,, uint256 u,) = feed.latestRoundData();
        assertEq(a, 5e18);
        assertEq(u, block.timestamp);
        vm.prank(owner);
        vm.expectRevert(SignedPriceFeed.BadPrice.selector);
        feed.forcePrice(0);
        // a signature dated before the forced price can't roll it back
        uint64 ts = uint64(block.timestamp - 1);
        bytes memory sig = _sign(3e18, ts);
        vm.expectRevert(SignedPriceFeed.NotNewer.selector);
        feed.update(3e18, ts, sig);
    }

    function test_setSignerAuth() public {
        address newSigner = vm.addr(0xB0B);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        feed.setSigner(newSigner);
        vm.prank(owner);
        vm.expectEmit(address(feed));
        emit SignedPriceFeed.SignerSet(newSigner);
        feed.setSigner(newSigner);
        assertEq(feed.signer(), newSigner);

        vm.warp(block.timestamp + 10);
        uint64 ts = uint64(block.timestamp);
        bytes memory oldKeySig = _sign(3e18, ts);
        vm.expectRevert(SignedPriceFeed.BadSignature.selector);
        feed.update(3e18, ts, oldKeySig);
        feed.update(3e18, ts, _sign(feed, 0xB0B, 3e18, ts, block.chainid));
    }

    function test_ownershipIsTwoStep() public {
        address safe = makeAddr("safe");
        vm.prank(owner);
        feed.transferOwnership(safe);
        assertEq(feed.owner(), owner);
        vm.prank(safe);
        feed.acceptOwnership();
        assertEq(feed.owner(), safe);
    }

    function test_quoteRegistryIntegration() public {
        MockCoin coin = new MockCoin();
        QuoteRegistry reg = new QuoteRegistry(address(this));
        reg.setPriceBounds(address(coin), 1e17, 100e18);
        reg.setQuote(address(coin), true, address(feed));
        assertEq(reg.usdPrice(address(coin)), 2e18);
        QuoteRegistry.CurveParams memory p0 = reg.curveParams(address(coin));
        assertEq(p0.quoteUsd, 2e18);

        // older than 26h: registry refuses until someone submits a fresh signature
        vm.warp(block.timestamp + 26 hours + 1);
        vm.expectRevert(QuoteRegistry.StalePrice.selector);
        reg.curveParams(address(coin));
        vm.expectRevert(QuoteRegistry.StalePrice.selector);
        reg.usdPrice(address(coin));

        uint64 ts = uint64(block.timestamp - 3);
        feed.update(4e18, ts, _sign(4e18, ts));
        assertEq(reg.usdPrice(address(coin)), 4e18);
        QuoteRegistry.CurveParams memory p1 = reg.curveParams(address(coin));
        assertEq(p1.quoteUsd, 4e18);
        // twice the price, half the virtual quote
        assertApproxEqAbs(uint256(p1.virtualQuote) * 2, p0.virtualQuote, 2);
        assertEq(p1.virtualTokens, p0.virtualTokens);

        // the registry's per-quote bounds still apply to signed prices
        vm.warp(block.timestamp + 10);
        ts = uint64(block.timestamp);
        feed.update(1000e18, ts, _sign(1000e18, ts));
        vm.expectRevert(QuoteRegistry.PriceOutOfBounds.selector);
        reg.curveParams(address(coin));
    }
}
