// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BridgeAttestor} from "../contracts/bridge/BridgeAttestor.sol";
import {StockEscrow} from "../contracts/bridge/StockEscrow.sol";
import {StockGateway} from "../contracts/bridge/StockGateway.sol";
import {BridgedStock} from "../contracts/bridge/BridgedStock.sol";

contract MockStock is ERC20 {
    /// Issuer blocklist, like a real stock token can impose: blocked addresses can't receive.
    mapping(address => bool) public blocked;

    constructor() ERC20("NVIDIA Robinhood Token", "NVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool on) external {
        blocked[a] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// Both bridge ends on one test chain: the route check is exercised by pointing each side's
/// "remote chain" at this chain id, and by signing transfers with the real contract addresses.
contract StockBridgeTest is Test {
    StockEscrow escrow; // "Robinhood Chain"
    StockGateway gateway; // "Avalanche"
    MockStock nvda;
    BridgedStock mNVDA;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice"); // already holds NVDA on Robinhood
    address bob = makeAddr("bob");

    uint256[] keys;
    address[] vals;

    function setUp() public {
        // three validators, sorted by address, threshold 2
        for (uint256 i = 1; i <= 3; ++i) keys.push(uint256(keccak256(abi.encode("validator", i))));
        _sortKeys();
        for (uint256 i; i < 3; ++i) vals.push(vm.addr(keys[i]));

        escrow = new StockEscrow(owner, block.chainid);
        gateway = new StockGateway(owner, block.chainid);
        nvda = new MockStock();

        vm.startPrank(owner);
        escrow.setValidators(vals, 2);
        gateway.setValidators(vals, 2);
        escrow.setRemote(address(gateway));
        gateway.setRemote(address(escrow));
        escrow.setGuardian(guardian);
        gateway.setGuardian(guardian);
        escrow.setSupported(address(nvda), true);
        mNVDA = gateway.createStock(address(nvda), "NVIDIA (AvaxHook bridged)", "mNVDA");
        gateway.setLimit(address(nvda), 1_000 ether);
        escrow.setLimit(address(nvda), 1_000 ether);
        vm.stopPrank();

        nvda.mint(alice, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _sortKeys() internal {
        for (uint256 i; i < keys.length; ++i)
            for (uint256 j = i + 1; j < keys.length; ++j)
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
    }

    function _lockMsg(uint64 nonce, address to, uint256 amount) internal view returns (BridgeAttestor.Transfer memory) {
        return BridgeAttestor.Transfer(block.chainid, address(escrow), nonce, block.chainid, address(gateway), address(nvda), to, amount);
    }

    function _burnMsg(uint64 nonce, address to, uint256 amount) internal view returns (BridgeAttestor.Transfer memory) {
        return BridgeAttestor.Transfer(block.chainid, address(gateway), nonce, block.chainid, address(escrow), address(nvda), to, amount);
    }

    function _sign(BridgeAttestor dst, BridgeAttestor.Transfer memory t, uint256[] memory signers) internal view returns (bytes[] memory sigs) {
        bytes32 digest = dst.hashTransfer(t);
        sigs = new bytes[](signers.length);
        for (uint256 i; i < signers.length; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[signers[i]], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _idx(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        (x[0], x[1]) = (a, b);
    }

    function _bridgeIn(address from, address to, uint256 amount) internal returns (uint64 nonce) {
        vm.startPrank(from);
        nvda.approve(address(escrow), amount);
        nonce = escrow.lock(address(nvda), amount, to);
        vm.stopPrank();
        BridgeAttestor.Transfer memory t = _lockMsg(nonce, to, amount);
        gateway.mint(t, _sign(gateway, t, _idx(0, 1)));
    }

    // ------------------------------------------------------------------ happy path

    function test_existingHolderBridgesOneToOne() public {
        _bridgeIn(alice, alice, 40 ether);
        assertEq(mNVDA.balanceOf(alice), 40 ether);
        assertEq(nvda.balanceOf(address(escrow)), 40 ether);
        assertEq(escrow.escrowedShares(address(nvda)), 40 ether);
        assertEq(mNVDA.totalSupply(), nvda.balanceOf(address(escrow))); // fully backed
    }

    function test_roundTripBackToRobinhood() public {
        _bridgeIn(alice, alice, 40 ether);
        vm.prank(alice);
        mNVDA.transfer(bob, 10 ether);

        vm.prank(bob);
        uint64 nonce = gateway.burn(address(nvda), 10 ether, bob);
        assertEq(mNVDA.totalSupply(), 30 ether);

        BridgeAttestor.Transfer memory t = _burnMsg(nonce, bob, 10 ether);
        escrow.release(t, _sign(escrow, t, _idx(1, 2)));
        assertEq(nvda.balanceOf(bob), 10 ether);
        assertEq(nvda.balanceOf(address(escrow)), 30 ether);
        assertEq(mNVDA.totalSupply(), nvda.balanceOf(address(escrow)));
    }

    // ------------------------------------------------------------------ attack surface

    function test_replayRejected() public {
        vm.startPrank(alice);
        nvda.approve(address(escrow), 5 ether);
        uint64 nonce = escrow.lock(address(nvda), 5 ether, alice);
        vm.stopPrank();
        BridgeAttestor.Transfer memory t = _lockMsg(nonce, alice, 5 ether);
        bytes[] memory sigs = _sign(gateway, t, _idx(0, 2));
        gateway.mint(t, sigs);
        vm.expectRevert(BridgeAttestor.AlreadyProcessed.selector);
        gateway.mint(t, sigs);
    }

    function test_belowThresholdRejected() public {
        BridgeAttestor.Transfer memory t = _lockMsg(1, alice, 5 ether);
        uint256[] memory one = new uint256[](1);
        bytes[] memory sigs = _sign(gateway, t, one);
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        gateway.mint(t, sigs);
    }

    function test_duplicateOrUnsortedSignaturesRejected() public {
        BridgeAttestor.Transfer memory t = _lockMsg(1, alice, 5 ether);
        bytes[] memory dup = _sign(gateway, t, _idx(1, 1)); // same validator twice
        bytes[] memory unsorted = _sign(gateway, t, _idx(2, 0)); // wrong order
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        gateway.mint(t, dup);
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        gateway.mint(t, unsorted);
    }

    function test_outsiderSignatureRejected() public {
        BridgeAttestor.Transfer memory t = _lockMsg(1, alice, 5 ether);
        bytes32 digest = gateway.hashTransfer(t);
        uint256 rogue = uint256(keccak256("rogue"));
        bytes[] memory sigs = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[0], digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(rogue, digest);
        bool rogueFirst = vm.addr(rogue) < vals[0];
        sigs[rogueFirst ? 0 : 1] = abi.encodePacked(r2, s2, v2);
        sigs[rogueFirst ? 1 : 0] = abi.encodePacked(r, s, v);
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        gateway.mint(t, sigs);
    }

    function test_signatureForOtherDestinationRejected() public {
        // A lock attestation can't be replayed as a release on the escrow.
        BridgeAttestor.Transfer memory t = _lockMsg(1, alice, 5 ether);
        bytes[] memory sigs = _sign(gateway, t, _idx(0, 1));
        vm.expectRevert(BridgeAttestor.WrongRoute.selector);
        escrow.release(t, sigs);
    }

    function test_cannotReleaseMoreThanEscrowed() public {
        _bridgeIn(alice, alice, 5 ether);
        // even with valid signatures (e.g. compromised majority), escrow can't pay out more than it holds per token
        BridgeAttestor.Transfer memory t = _burnMsg(1, bob, 6 ether);
        bytes[] memory sigs = _sign(escrow, t, _idx(0, 1));
        vm.expectRevert();
        escrow.release(t, sigs);
    }

    function test_dailyLimit() public {
        vm.startPrank(owner);
        gateway.setLimit(address(nvda), 10 ether);
        escrow.setLimit(address(nvda), 10 ether);
        vm.stopPrank();
        _bridgeIn(alice, alice, 10 ether);
        vm.startPrank(alice);
        nvda.approve(address(escrow), 1 ether);
        uint64 nonce = escrow.lock(address(nvda), 1 ether, alice);
        vm.stopPrank();
        BridgeAttestor.Transfer memory t = _lockMsg(nonce, alice, 1 ether);
        bytes[] memory sigs = _sign(gateway, t, _idx(0, 1));
        vm.expectRevert(abi.encodeWithSelector(BridgeAttestor.LimitExceeded.selector, 1 ether, 0));
        gateway.mint(t, sigs);
        vm.warp(block.timestamp + 1 days);
        gateway.mint(t, sigs); // next window
        assertEq(mNVDA.balanceOf(alice), 11 ether);
    }

    function _setLimits(uint128 perDay) internal {
        vm.startPrank(owner);
        gateway.setLimit(address(nvda), perDay);
        escrow.setLimit(address(nvda), perDay);
        vm.stopPrank();
    }

    /// Mints `amount` on the gateway for a fresh lock; returns false (and mints nothing) if over the limit.
    function _tryBridgeIn(uint256 amount) internal returns (bool) {
        nvda.mint(alice, amount);
        vm.startPrank(alice);
        nvda.approve(address(escrow), amount);
        uint64 nonce = escrow.lock(address(nvda), amount, alice);
        vm.stopPrank();
        BridgeAttestor.Transfer memory t = _lockMsg(nonce, alice, amount);
        bytes[] memory sigs = _sign(gateway, t, _idx(0, 1));
        try gateway.mint(t, sigs) {
            return true;
        } catch {
            return false;
        }
    }

    /// The old fixed window let a full day's limit through right before its edge and another right
    /// after. The bucket refills continuously instead.
    function test_rateLimit_noDoubleAtWindowEdge() public {
        _setLimits(10 ether);
        assertTrue(_tryBridgeIn(10 ether));
        assertEq(gateway.available(address(nvda)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days - 1); // the old window's edge
        assertFalse(_tryBridgeIn(10 ether));
        vm.warp(vm.getBlockTimestamp() + 2); // just past it
        assertTrue(_tryBridgeIn(10 ether)); // a full day has drained
        assertEq(gateway.available(address(nvda)), 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(_tryBridgeIn(1 ether)); // not another full day right away
    }

    function test_rateLimit_refillsLinearly() public {
        _setLimits(10 ether);
        assertTrue(_tryBridgeIn(10 ether));
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        assertEq(gateway.available(address(nvda)), 2.5 ether);
        assertFalse(_tryBridgeIn(3 ether));
        assertTrue(_tryBridgeIn(2.5 ether));
        assertEq(gateway.available(address(nvda)), 0);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(gateway.available(address(nvda)), 5 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(gateway.available(address(nvda)), 10 ether); // capped at one day
    }

    function test_rateLimit_setLimitSettlesAtOldRate() public {
        _setLimits(10 ether);
        assertTrue(_tryBridgeIn(10 ether));
        vm.warp(vm.getBlockTimestamp() + 12 hours); // 5 drained at the old rate
        vm.prank(owner);
        gateway.setLimit(address(nvda), 20 ether);
        assertEq(gateway.available(address(nvda)), 15 ether);
        (, uint128 used, uint64 updatedAt) = gateway.limits(address(nvda));
        assertEq(used, 5 ether);
        assertEq(updatedAt, vm.getBlockTimestamp());
        vm.prank(owner);
        gateway.setLimit(address(nvda), 0); // close the route
        assertEq(gateway.available(address(nvda)), 0);
        assertFalse(_tryBridgeIn(1));
    }

    /// Over any interval of length dt, at most perDay + perDay * dt / 1 day gets in.
    function testFuzz_rateLimit_bound(uint64[6] memory gaps, uint96[6] memory amounts) public {
        uint128 perDay = 10 ether;
        _setLimits(perDay);
        // track time locally: under via-ir, block.timestamp reads may not observe vm.warp
        uint256 start = vm.getBlockTimestamp();
        uint256 t = start;
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            t += bound(gaps[i], 0, 2 days);
            vm.warp(t);
            uint256 a = bound(amounts[i], 1, perDay);
            if (_tryBridgeIn(a)) total += a;
            assertLe(total, perDay + (uint256(perDay) * (t - start)) / 1 days);
        }
    }

    function test_guardianPausesOwnerUnpauses() public {
        vm.prank(guardian);
        escrow.pause();
        vm.startPrank(alice);
        nvda.approve(address(escrow), 1 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.lock(address(nvda), 1 ether, alice);
        vm.stopPrank();
        vm.prank(guardian);
        vm.expectRevert();
        escrow.unpause();
        vm.prank(owner);
        escrow.unpause();
    }

    function test_onlyGatewayMintsBridgedToken() public {
        vm.expectRevert(BridgedStock.OnlyGateway.selector);
        mNVDA.mint(bob, 1 ether);
    }

    function test_unsupportedTokenCannotLock() public {
        MockStock other = new MockStock();
        other.mint(alice, 1 ether);
        vm.startPrank(alice);
        other.approve(address(escrow), 1 ether);
        vm.expectRevert(StockEscrow.Unsupported.selector);
        escrow.lock(address(other), 1 ether, alice);
        vm.stopPrank();
    }

    function test_noValidatorsSetRejectsEmptySignatures() public {
        StockEscrow e = new StockEscrow(owner, block.chainid);
        StockGateway g = new StockGateway(owner, block.chainid);
        vm.startPrank(owner);
        e.setRemote(address(g));
        g.setRemote(address(e));
        e.setSupported(address(nvda), true);
        e.setLimit(address(nvda), 1_000 ether);
        g.createStock(address(nvda), "NVIDIA (AvaxHook bridged)", "mNVDA");
        g.setLimit(address(nvda), 1_000 ether);
        vm.stopPrank();
        assertEq(e.threshold(), 0);
        bytes[] memory none = new bytes[](0);
        BridgeAttestor.Transfer memory t =
            BridgeAttestor.Transfer(block.chainid, address(g), 1, block.chainid, address(e), address(nvda), bob, 1 ether);
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        e.release(t, none);
        t = BridgeAttestor.Transfer(block.chainid, address(e), 1, block.chainid, address(g), address(nvda), bob, 1 ether);
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        g.mint(t, none);
    }

    function _stuckRelease() internal returns (BridgeAttestor.Transfer memory t, bytes[] memory sigs) {
        _bridgeIn(alice, alice, 10 ether);
        vm.prank(alice);
        uint64 nonce = gateway.burn(address(nvda), 10 ether, bob);
        t = _burnMsg(nonce, bob, 10 ether);
        sigs = _sign(escrow, t, _idx(1, 2));
        nvda.setBlocked(bob, true); // issuer blocklists the recipient
        vm.expectRevert();
        escrow.release(t, sigs);
    }

    function test_redirectStuckRelease() public {
        (BridgeAttestor.Transfer memory t, bytes[] memory sigs) = _stuckRelease();
        address fresh = makeAddr("bobNewWallet");

        vm.prank(alice);
        vm.expectRevert();
        escrow.redirectRelease(t, sigs, fresh); // owner only

        vm.prank(owner);
        vm.expectEmit(address(escrow));
        emit StockEscrow.ReleaseRedirected(t.nonce, address(nvda), bob, fresh, 10 ether, 10 ether);
        escrow.redirectRelease(t, sigs, fresh);
        assertEq(nvda.balanceOf(fresh), 10 ether);
        assertEq(escrow.escrowedShares(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(escrow)), 0);

        // no second payout, by either path
        nvda.setBlocked(bob, false);
        vm.expectRevert(BridgeAttestor.AlreadyProcessed.selector);
        escrow.release(t, sigs);
        vm.prank(owner);
        vm.expectRevert(BridgeAttestor.AlreadyProcessed.selector);
        escrow.redirectRelease(t, sigs, fresh);
    }

    function test_redirectPaysOriginalRecipientWhenItWorks() public {
        (BridgeAttestor.Transfer memory t, bytes[] memory sigs) = _stuckRelease();
        nvda.setBlocked(bob, false); // the block was lifted: the owner can't divert it
        address other = makeAddr("other");
        vm.prank(owner);
        escrow.redirectRelease(t, sigs, other);
        assertEq(nvda.balanceOf(bob), 10 ether);
        assertEq(nvda.balanceOf(other), 0);
        vm.expectRevert(BridgeAttestor.AlreadyProcessed.selector);
        escrow.release(t, sigs);
    }

    function test_redirectNeedsValidSignaturesAndRecipient() public {
        (BridgeAttestor.Transfer memory t, bytes[] memory sigs) = _stuckRelease();
        vm.startPrank(owner);
        vm.expectRevert(BridgeAttestor.BadRecipient.selector);
        escrow.redirectRelease(t, sigs, address(0));
        bytes[] memory none = new bytes[](0);
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        escrow.redirectRelease(t, none, makeAddr("x"));
        BridgeAttestor.Transfer memory bigger = _burnMsg(t.nonce, bob, 11 ether); // signatures don't cover it
        vm.expectRevert(BridgeAttestor.BadSignatures.selector);
        escrow.redirectRelease(bigger, sigs, makeAddr("x"));
        vm.stopPrank();
    }

    function test_validatorSetNeedsMajority() public {
        vm.startPrank(owner);
        vm.expectRevert(BridgeAttestor.BadValidators.selector);
        escrow.setValidators(vals, 1); // 1 of 3 is not a majority
        address[] memory one = new address[](1);
        one[0] = owner;
        vm.expectRevert(BridgeAttestor.BadValidators.selector);
        escrow.setValidators(one, 1); // an owner-only 1-of-1 set is refused
        address[] memory unsorted = new address[](3);
        (unsorted[0], unsorted[1], unsorted[2]) = (vals[1], vals[0], vals[2]);
        vm.expectRevert(BridgeAttestor.BadValidators.selector);
        escrow.setValidators(unsorted, 2);
        vm.stopPrank();
    }

    function test_transferAboveDailyLimitRefusedAtSource() public {
        vm.prank(owner);
        escrow.setLimit(address(nvda), 10 ether);
        vm.startPrank(alice);
        nvda.approve(address(escrow), 11 ether);
        vm.expectRevert(abi.encodeWithSelector(BridgeAttestor.OverTransferLimit.selector, 11 ether, 10 ether));
        escrow.lock(address(nvda), 11 ether, alice);
        vm.stopPrank();
    }

    function test_bridgeContractsCantBeRecipients() public {
        vm.startPrank(alice);
        nvda.approve(address(escrow), 1 ether);
        vm.expectRevert(BridgeAttestor.BadRecipient.selector);
        escrow.lock(address(nvda), 1 ether, address(gateway));
        vm.stopPrank();
    }

    function test_replayKeyedBySourceContract() public {
        _bridgeIn(alice, alice, 1 ether);
        assertTrue(gateway.isProcessed(address(escrow), 1));
        assertFalse(gateway.isProcessed(address(0xBEEF), 1)); // a redeployed remote starts clean
    }
}
