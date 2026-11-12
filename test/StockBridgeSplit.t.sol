// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BridgeAttestor} from "../contracts/bridge/BridgeAttestor.sol";
import {StockEscrow} from "../contracts/bridge/StockEscrow.sol";
import {StockGateway} from "../contracts/bridge/StockGateway.sol";
import {BridgedStock} from "../contracts/bridge/BridgedStock.sol";

/// A stock token whose corporate actions rebase every balance: balances are raw units times a
/// multiplier, so a 2:1 split doubles what everyone (including the escrow) holds and a 1:10 reverse
/// split cuts it to a tenth. Transfers move `amount / multiplier` raw units, rounded down like a real
/// scaled-balance token.
contract SplitStock {
    string public constant name = "NVIDIA Robinhood Token";
    string public constant symbol = "NVDA";
    uint8 public constant decimals = 18;
    uint256 public multiplier = 1e18;
    mapping(address => uint256) public raw;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalRaw;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function balanceOf(address a) public view returns (uint256) {
        return raw[a] * multiplier / 1e18;
    }

    function totalSupply() external view returns (uint256) {
        return totalRaw * multiplier / 1e18;
    }

    function mint(address to, uint256 amount) external {
        uint256 r = amount * 1e18 / multiplier;
        raw[to] += r;
        totalRaw += r;
    }

    function split(uint256 num, uint256 den) external {
        multiplier = multiplier * num / den;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _move(msg.sender, to, v);
        return true;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        allowance[from][msg.sender] -= v;
        _move(from, to, v);
        return true;
    }

    function _move(address from, address to, uint256 v) internal {
        uint256 r = v * 1e18 / multiplier;
        raw[from] -= r;
        raw[to] += r;
        emit Transfer(from, to, v);
    }
}

contract StockBridgeSplitTest is Test {
    StockEscrow escrow;
    StockGateway gateway;
    SplitStock nvda;
    BridgedStock mNVDA;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256[] keys;

    function setUp() public {
        for (uint256 i = 1; i <= 3; ++i) keys.push(uint256(keccak256(abi.encode("validator", i))));
        for (uint256 i; i < 3; ++i)
            for (uint256 j = i + 1; j < 3; ++j)
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
        address[] memory vals = new address[](3);
        for (uint256 i; i < 3; ++i) vals[i] = vm.addr(keys[i]);

        escrow = new StockEscrow(owner, block.chainid);
        gateway = new StockGateway(owner, block.chainid);
        nvda = new SplitStock();

        vm.startPrank(owner);
        escrow.setValidators(vals, 2);
        gateway.setValidators(vals, 2);
        escrow.setRemote(address(gateway));
        gateway.setRemote(address(escrow));
        escrow.setGuardian(guardian);
        gateway.setGuardian(guardian);
        escrow.setSupported(address(nvda), true);
        mNVDA = gateway.createStock(address(nvda), "NVIDIA (AvaxHook bridged)", "mNVDA");
        gateway.setLimit(address(nvda), 1e30);
        escrow.setLimit(address(nvda), 1e30);
        vm.stopPrank();

        nvda.mint(alice, 100 ether);
        nvda.mint(bob, 100 ether);
        nvda.mint(carol, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _sign(BridgeAttestor dst, BridgeAttestor.Transfer memory t) internal view returns (bytes[] memory sigs) {
        bytes32 digest = dst.hashTransfer(t);
        sigs = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    /// Lock on "Robinhood", mint on "Avalanche" the shares the Locked event carried.
    function _bridgeIn(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        nvda.approve(address(escrow), amount);
        uint256 before = escrow.escrowedShares(address(nvda));
        uint64 nonce = escrow.lock(address(nvda), amount, who);
        vm.stopPrank();
        shares = escrow.escrowedShares(address(nvda)) - before;
        BridgeAttestor.Transfer memory t =
            BridgeAttestor.Transfer(block.chainid, address(escrow), nonce, block.chainid, address(gateway), address(nvda), who, shares);
        gateway.mint(t, _sign(gateway, t));
    }

    /// Burn on "Avalanche"; returns the signed release message (not yet submitted).
    function _burn(address who, uint256 shares) internal returns (BridgeAttestor.Transfer memory t, bytes[] memory sigs) {
        vm.prank(who);
        uint64 nonce = gateway.burn(address(nvda), shares, who);
        t = BridgeAttestor.Transfer(block.chainid, address(gateway), nonce, block.chainid, address(escrow), address(nvda), who, shares);
        sigs = _sign(escrow, t);
    }

    function _redeem(address who, uint256 shares) internal returns (uint256 got) {
        (BridgeAttestor.Transfer memory t, bytes[] memory sigs) = _burn(who, shares);
        uint256 before = nvda.balanceOf(who);
        escrow.release(t, sigs);
        got = nvda.balanceOf(who) - before;
    }

    /// The corporate action as run in production: guardian pauses the stock, the token rebases,
    /// the Safe applies the same ratio and resumes.
    function _split(uint256 num, uint256 den) internal {
        vm.prank(guardian);
        escrow.pauseToken(address(nvda));
        nvda.split(num, den);
        vm.startPrank(owner);
        escrow.applySplit(address(nvda), num, den);
        escrow.unpauseToken(address(nvda));
        vm.stopPrank();
    }

    function _assertBacked() internal view {
        assertLe(escrow.backingRequired(address(nvda)), nvda.balanceOf(address(escrow)), "backing");
        assertEq(mNVDA.totalSupply(), escrow.escrowedShares(address(nvda)), "supply == shares");
    }

    // ------------------------------------------------------------------ splits

    function test_split2for1_holdersRedeemFullPostSplitAmount() public {
        assertEq(_bridgeIn(alice, 40 ether), 40 ether); // 1:1 before any split
        assertEq(_bridgeIn(bob, 10 ether), 10 ether);
        _split(2, 1);
        assertEq(nvda.balanceOf(address(escrow)), 100 ether); // escrow now holds 2x origin units
        assertEq(escrow.originPerShare(address(nvda)), 2e18);
        assertEq(mNVDA.totalSupply(), 50 ether); // no holder touched on Avalanche
        _assertBacked();

        assertEq(_redeem(alice, 40 ether), 80 ether); // full post-split amount
        assertEq(_bridgeIn(carol, 6 ether), 3 ether); // new locks at the new rate
        assertEq(_redeem(bob, 10 ether), 20 ether);
        assertEq(_redeem(carol, 3 ether), 6 ether);
        assertEq(nvda.balanceOf(address(escrow)), 0); // nothing stranded
        assertEq(escrow.escrowedShares(address(nvda)), 0);
        assertEq(mNVDA.totalSupply(), 0);
    }

    function test_reverseSplit1for10_redeemsTenth() public {
        _bridgeIn(alice, 40 ether);
        _bridgeIn(bob, 15 ether);
        _split(1, 10);
        assertEq(nvda.balanceOf(address(escrow)), 5.5 ether);
        assertEq(escrow.originPerShare(address(nvda)), 0.1e18);
        _assertBacked();
        assertEq(_redeem(alice, 40 ether), 4 ether);
        assertEq(_bridgeIn(carol, 1 ether), 10 ether); // 1 post-split NVDA = 10 shares
        assertEq(_redeem(bob, 15 ether), 1.5 ether);
        assertEq(_redeem(carol, 10 ether), 1 ether);
        assertEq(nvda.balanceOf(address(escrow)), 0);
        assertEq(escrow.escrowedShares(address(nvda)), 0);
    }

    function test_burnSignedBeforeSplitSettlesAtNewRate() public {
        _bridgeIn(alice, 40 ether);
        (BridgeAttestor.Transfer memory t, bytes[] memory sigs) = _burn(alice, 25 ether); // in flight
        _split(2, 1);
        uint256 before = nvda.balanceOf(alice);
        escrow.release(t, sigs); // same signatures, shares are rate-free
        assertEq(nvda.balanceOf(alice) - before, 50 ether);
        assertEq(_redeem(alice, 15 ether), 30 ether);
        assertEq(nvda.balanceOf(address(escrow)), 0);
    }

    function test_splitTwiceComposes() public {
        _bridgeIn(alice, 30 ether);
        _split(3, 1);
        _split(1, 2);
        assertEq(escrow.originPerShare(address(nvda)), 1.5e18);
        assertEq(_redeem(alice, 30 ether), 45 ether);
        assertEq(nvda.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------------------------ owner can't drain or inflate

    function test_cannotInflateRateBeyondBalance() public {
        _bridgeIn(alice, 40 ether);
        vm.prank(guardian);
        escrow.pauseToken(address(nvda));
        vm.startPrank(owner);
        // no split happened: doubling the rate would let shares take twice the balance
        vm.expectRevert(abi.encodeWithSelector(StockEscrow.Undercollateralized.selector, 80 ether, 40 ether));
        escrow.applySplit(address(nvda), 2, 1);
        vm.stopPrank();

        nvda.split(2, 1);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(StockEscrow.Undercollateralized.selector, 120 ether, 80 ether));
        escrow.applySplit(address(nvda), 3, 1); // more than the real 2:1
        escrow.applySplit(address(nvda), 2, 1);
        vm.stopPrank();
    }

    function test_noOverReleaseAfterSplit() public {
        _bridgeIn(alice, 40 ether);
        _split(2, 1);
        // a forged/compromised attestation for more shares than exist still can't take more
        BridgeAttestor.Transfer memory t =
            BridgeAttestor.Transfer(block.chainid, address(gateway), 99, block.chainid, address(escrow), address(nvda), bob, 41 ether);
        bytes[] memory sigs = _sign(escrow, t);
        vm.expectRevert(); // escrowedShares underflow
        escrow.release(t, sigs);
    }

    function test_applySplitNeedsPauseAndOwner() public {
        _bridgeIn(alice, 10 ether);
        nvda.split(2, 1);
        vm.prank(owner);
        vm.expectRevert(StockEscrow.NotPausedForSplit.selector);
        escrow.applySplit(address(nvda), 2, 1);

        vm.prank(alice);
        vm.expectRevert(BridgeAttestor.NotGuardian.selector);
        escrow.pauseToken(address(nvda));
        vm.prank(guardian);
        escrow.pauseToken(address(nvda));
        vm.prank(guardian);
        vm.expectRevert(); // Ownable
        escrow.applySplit(address(nvda), 2, 1);
        vm.prank(guardian);
        vm.expectRevert(); // only the owner resumes
        escrow.unpauseToken(address(nvda));

        vm.startPrank(owner);
        vm.expectRevert(StockEscrow.BadSplit.selector);
        escrow.applySplit(address(nvda), 0, 1);
        vm.expectRevert(StockEscrow.BadSplit.selector);
        escrow.applySplit(address(nvda), 1001, 1);
        escrow.applySplit(address(nvda), 2, 1);
        vm.stopPrank();
    }

    function test_tokenPauseBlocksLockAndRelease() public {
        _bridgeIn(alice, 10 ether);
        (BridgeAttestor.Transfer memory t, bytes[] memory sigs) = _burn(alice, 5 ether);
        vm.prank(guardian);
        escrow.pauseToken(address(nvda));
        vm.startPrank(alice);
        nvda.approve(address(escrow), 1 ether);
        vm.expectRevert(StockEscrow.TokenIsPaused.selector);
        escrow.lock(address(nvda), 1 ether, alice);
        vm.stopPrank();
        vm.expectRevert(StockEscrow.TokenIsPaused.selector);
        escrow.release(t, sigs);
        vm.prank(owner);
        escrow.unpauseToken(address(nvda));
        escrow.release(t, sigs); // relayer retry succeeds
        assertEq(nvda.balanceOf(alice), 95 ether);
    }

    /// Without the pause, a lock between the token's split and applySplit would get shares at the
    /// stale rate; the invariant then refuses the full ratio, so the race can never over-pay anyone.
    function test_staleRateLockCannotBeRatified() public {
        _bridgeIn(alice, 40 ether);
        nvda.split(2, 1); // escrow 80
        _bridgeIn(bob, 20 ether); // 20 shares at the stale 1:1 (should have been 10)
        vm.prank(guardian);
        escrow.pauseToken(address(nvda));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StockEscrow.Undercollateralized.selector, 120 ether, 100 ether));
        escrow.applySplit(address(nvda), 2, 1);
        _assertBacked();
    }

    /// An issuer burn from the escrow can be socialised pro rata with a lower rate; never a higher one.
    function test_lossCanBeSocialisedDownOnly() public {
        _bridgeIn(alice, 40 ether);
        _bridgeIn(bob, 60 ether);
        vm.prank(address(escrow));
        nvda.transfer(address(0xdead), 10 ether); // 10% gone
        vm.prank(guardian);
        escrow.pauseToken(address(nvda));
        vm.startPrank(owner);
        escrow.applySplit(address(nvda), 9, 10);
        escrow.unpauseToken(address(nvda));
        vm.stopPrank();
        assertEq(_redeem(alice, 40 ether), 36 ether);
        assertEq(_redeem(bob, 60 ether), 54 ether);
        assertEq(nvda.balanceOf(address(escrow)), 0);
    }

    /// Random locks, burns, splits and reverse splits: backing always holds and, once every share is
    /// redeemed, at most rounding dust is left in the escrow.
    function testFuzz_splitsKeepBacking(uint96[8] memory amounts, uint8[8] memory ops) public {
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 8; ++i) {
            address u = who[i % 3];
            uint8 op = ops[i] % 4;
            if (op == 0) {
                uint256 a = bound(amounts[i], 1e6, 50 ether);
                nvda.mint(u, a);
                _bridgeIn(u, a);
            } else if (op == 1) {
                uint256 bal = mNVDA.balanceOf(u);
                if (bal == 0) continue;
                uint256 s = bound(amounts[i], 1, bal);
                uint256 expect = escrow.toAmount(address(nvda), s);
                assertApproxEqAbs(_redeem(u, s), expect, nvda.multiplier() / 1e18 + 2); // scaled-balance rounding
            } else if (op == 2) {
                _split(2, 1);
            } else {
                _split(1, 10);
            }
            _assertBacked();
        }
        for (uint256 k; k < 3; ++k) {
            uint256 bal = mNVDA.balanceOf(who[k]);
            if (bal != 0) _redeem(who[k], bal);
        }
        assertEq(escrow.escrowedShares(address(nvda)), 0);
        assertLe(nvda.balanceOf(address(escrow)), 1e15); // rounding dust only
    }
}
