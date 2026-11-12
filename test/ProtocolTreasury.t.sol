// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolTreasury} from "../contracts/ProtocolTreasury.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// USDT-style: transfer returns nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = 1_000_000 ether;
    }

    function transfer(address to, uint256 v) external {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
    }
}

/// Returns false instead of reverting.
contract FalseToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract Rejector {
    receive() external payable {
        revert("no");
    }
}

/// Re-enters the treasury when it receives AVAX.
contract Reenterer {
    ProtocolTreasury public t;

    function set(ProtocolTreasury t_) external {
        t = t_;
    }

    receive() external payable {
        t.withdrawNative(payable(address(this)), 1, "");
    }
}

contract StipendSender {
    function send(address payable to) external payable {
        to.transfer(msg.value); // 2300 gas stipend
    }
}

contract ProtocolTreasuryTest is Test {
    ProtocolTreasury treasury;
    MockToken token;
    address admin = makeAddr("admin");
    address mm = makeAddr("marketMaker");
    address rando = makeAddr("rando");

    function setUp() public {
        treasury = new ProtocolTreasury(admin);
        token = new MockToken();
        token.transfer(address(treasury), 100_000 ether);
        vm.deal(address(this), 10 ether);
        (bool ok,) = address(treasury).call{value: 5 ether}("");
        assertTrue(ok);
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ProtocolTreasury(address(0));
    }

    function test_ownerWithdrawsToken() public {
        vm.expectEmit(address(treasury));
        emit ProtocolTreasury.TokenWithdrawn(address(token), mm, 40_000 ether, "MM");
        vm.prank(admin);
        treasury.withdrawToken(IERC20(address(token)), mm, 40_000 ether, "MM");
        assertEq(token.balanceOf(mm), 40_000 ether);
        assertEq(token.balanceOf(address(treasury)), 60_000 ether);
    }

    function test_ownerWithdrawsNative() public {
        vm.prank(admin);
        treasury.withdrawNative(payable(mm), 2 ether, "listing fee");
        assertEq(mm.balance, 2 ether);
        assertEq(address(treasury).balance, 3 ether);
    }

    function test_withdrawMoreThanBalanceReverts() public {
        vm.startPrank(admin);
        vm.expectRevert();
        treasury.withdrawToken(IERC20(address(token)), mm, 100_001 ether, "");
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 5 ether, 6 ether));
        treasury.withdrawNative(payable(mm), 6 ether, "");
        vm.stopPrank();
    }

    function test_noReturnTokenWorks() public {
        NoReturnToken nrt = new NoReturnToken();
        nrt.transfer(address(treasury), 10 ether);
        vm.prank(admin);
        treasury.withdrawToken(IERC20(address(nrt)), mm, 10 ether, "");
        assertEq(nrt.balanceOf(mm), 10 ether);
    }

    function test_falseReturningTokenReverts() public {
        FalseToken ft = new FalseToken();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(ft)));
        treasury.withdrawToken(IERC20(address(ft)), mm, 1, "");
    }

    function test_rejectingRecipientReverts() public {
        Rejector r = new Rejector();
        vm.prank(admin);
        vm.expectRevert();
        treasury.withdrawNative(payable(address(r)), 1 ether, "");
        assertEq(address(treasury).balance, 5 ether);
    }

    function test_reentryBlockedByOwnerCheck() public {
        Reenterer r = new Reenterer();
        r.set(treasury);
        vm.prank(admin);
        vm.expectRevert(); // inner call: Reenterer is not owner
        treasury.withdrawNative(payable(address(r)), 1 ether, "");
        assertEq(address(treasury).balance, 5 ether);
    }

    function test_acceptsAvaxWithStipend() public {
        StipendSender s = new StipendSender();
        s.send{value: 1 ether}(payable(address(treasury)));
        assertEq(address(treasury).balance, 6 ether);
    }

    function test_unknownCalldataReverts() public {
        (bool ok,) = address(treasury).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
    }

    function test_nonOwnerCannotWithdraw() public {
        vm.startPrank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        treasury.withdrawToken(IERC20(address(token)), rando, 1, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        treasury.withdrawNative(payable(rando), 1, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        treasury.transferOwnership(rando);
        vm.stopPrank();
    }

    function testFuzz_onlyOwnerCanWithdraw(address caller, uint256 amount) public {
        vm.assume(caller != admin);
        amount = bound(amount, 0, 100_000 ether);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        treasury.withdrawToken(IERC20(address(token)), caller, amount, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        treasury.withdrawNative(payable(caller), amount % 5 ether, "");
        vm.stopPrank();
        assertEq(token.balanceOf(address(treasury)), 100_000 ether);
        assertEq(address(treasury).balance, 5 ether);
    }

    function testFuzz_ownerWithdrawsExact(uint256 amount) public {
        amount = bound(amount, 0, 100_000 ether);
        vm.prank(admin);
        treasury.withdrawToken(IERC20(address(token)), mm, amount, "");
        assertEq(token.balanceOf(mm), amount);
        assertEq(token.balanceOf(address(treasury)), 100_000 ether - amount);
    }

    function test_zeroAddressRejected() public {
        vm.startPrank(admin);
        vm.expectRevert(ProtocolTreasury.ZeroAddress.selector);
        treasury.withdrawToken(IERC20(address(token)), address(0), 1, "");
        vm.expectRevert(ProtocolTreasury.ZeroAddress.selector);
        treasury.withdrawNative(payable(address(0)), 1, "");
        vm.stopPrank();
    }

    function test_renounceDisabled() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolTreasury.RenounceDisabled.selector);
        treasury.renounceOwnership();
        assertEq(treasury.owner(), admin);
    }

    function test_twoStepOwnership() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        treasury.transferOwnership(newAdmin);
        assertEq(treasury.owner(), admin);
        assertEq(treasury.pendingOwner(), newAdmin);

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        treasury.acceptOwnership();

        vm.prank(newAdmin);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), newAdmin);
        assertEq(treasury.pendingOwner(), address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        treasury.withdrawToken(IERC20(address(token)), admin, 1, "");
    }

    function test_pendingTransferCanBeCancelled() public {
        address wrong = makeAddr("typo");
        vm.startPrank(admin);
        treasury.transferOwnership(wrong);
        treasury.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(wrong);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, wrong));
        treasury.acceptOwnership();
        assertEq(treasury.owner(), admin);
    }
}

/// Mainnet fork: the real $HOOK goes dev wallet -> treasury (owned by the Safe) -> back out.
///   forge test --match-contract ProtocolTreasuryFork --fork-url https://api.avax.network/ext/bc/C/rpc
contract ProtocolTreasuryFork is Test {
    IERC20 constant HOOK = IERC20(0x898D93e5BF6ee61a03f50CB0cdBF9C3751dA8Dc7);
    address constant DEV = 0x7149FaF83059A6c8274441898C3fD5569F14614d;
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;

    function test_fork_hookInAndOut() public {
        if (block.chainid != 43114) return;
        ProtocolTreasury t = new ProtocolTreasury(SAFE);
        uint256 bal = HOOK.balanceOf(DEV);
        assertGt(bal, 0);

        vm.prank(DEV);
        HOOK.transfer(address(t), bal);
        assertEq(HOOK.balanceOf(address(t)), bal);
        assertEq(HOOK.balanceOf(DEV), 0);

        vm.prank(DEV);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEV));
        t.withdrawToken(HOOK, DEV, 1, "");

        address mm = makeAddr("mm");
        vm.prank(SAFE);
        t.withdrawToken(HOOK, mm, bal / 4, "MM");
        assertEq(HOOK.balanceOf(mm), bal / 4);
        assertEq(HOOK.balanceOf(address(t)), bal - bal / 4);
    }
}
