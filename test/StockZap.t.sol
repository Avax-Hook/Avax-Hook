// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StockZap, IV3SwapRouter, IStockEscrow, IWETH9} from "../contracts/bridge/StockZap.sol";

interface IEscrowView {
    function limits(address) external view returns (uint128 perDay, uint128 used, uint64 updatedAt);
    function originPerShare(address) external view returns (uint256);
    function owner() external view returns (address);
    function setLimit(address originToken, uint128 perDay) external;
}

interface IPermitToken {
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// Fork test against Robinhood Chain mainnet (4663): the live Uniswap v3 deployment, the real NVDA token
/// and the live AvaxHook StockEscrow. Needs ROBINHOOD_FORK_URL or ALCHEMY_RHC_URL (an RPC that keeps
/// recent state; the public RPC prunes after ~10 min, which is enough for one run). Skipped without it.
contract StockZapForkTest is Test {
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant ESCROW = 0xa5D1615cd93D64F74B2eD39fB9c3D79216657613;
    address constant NVDA_WETH_POOL = 0x62AB521f71431f78ac374CdbadC6cda3c8916b6C; // Uniswap v3 NVDA/WETH 0.05%
    uint24 constant FEE = 500;

    bytes32 constant LOCKED_SIG = keccak256("Locked(uint64,address,address,address,uint256,uint256,uint256)");

    StockZap zap;
    address avaxUser = makeAddr("avaxUser");
    address relaySolver = makeAddr("relayMulticaller"); // Relay executes through a Multicaller, not the user

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_FORK_URL", vm.envOr("ALCHEMY_RHC_URL", string("")));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663);
        zap = new StockZap(IV3SwapRouter(ROUTER), IStockEscrow(ESCROW), IWETH9(WETH));
        vm.deal(relaySolver, 10 ether);
    }

    function _buyPath() internal pure returns (bytes memory) {
        return abi.encodePacked(WETH, FEE, NVDA);
    }

    function _sellPath() internal pure returns (bytes memory) {
        return abi.encodePacked(NVDA, FEE, WETH);
    }

    function test_buyAndBridge_swapsAndLocksForRecipient() public {
        uint256 escrowBal = IERC20(NVDA).balanceOf(ESCROW);
        uint256 escrowShares = IStockEscrow(ESCROW).escrowedShares(NVDA);

        vm.recordLogs();
        vm.prank(relaySolver);
        (uint64 nonce, uint256 shares) = zap.buyAndBridge{value: 0.02 ether}(_buyPath(), 0.1e18, avaxUser, block.timestamp + 60);

        // ~0.02 ETH ≈ $54 ≈ 0.23 NVDA
        assertGt(shares, 0.2e18);
        assertLt(shares, 0.3e18);
        assertEq(IStockEscrow(ESCROW).escrowedShares(NVDA), escrowShares + shares, "escrowed shares");
        uint256 rate = IEscrowView(ESCROW).originPerShare(NVDA);
        assertGe(IERC20(NVDA).balanceOf(ESCROW) - escrowBal, (shares * rate) / 1e18, "escrow got the stock");
        // the zap keeps nothing
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(zap)), 0);
        assertEq(IERC20(NVDA).allowance(address(zap), ESCROW), 0);

        // Locked(nonce, NVDA, from = zap, recipient = avaxUser, shares, amount, dstChainId 43114)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != ESCROW || logs[i].topics[0] != LOCKED_SIG) continue;
            found = true;
            assertEq(uint64(uint256(logs[i].topics[1])), nonce);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), NVDA);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(zap));
            (address recipient, uint256 s,, uint256 dst) = abi.decode(logs[i].data, (address, uint256, uint256, uint256));
            assertEq(recipient, avaxUser, "bridge recipient");
            assertEq(s, shares);
            assertEq(dst, 43114);
        }
        assertTrue(found, "Locked event");
    }

    function test_buyAndBridge_viaUsdgTwoHops() public {
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDG, uint24(500), NVDA);
        vm.prank(relaySolver);
        (, uint256 shares) = zap.buyAndBridge{value: 0.01 ether}(path, 0.05e18, avaxUser, block.timestamp + 60);
        assertGt(shares, 0.09e18);
    }

    function test_buyAndBridge_slippageReverts() public {
        vm.prank(relaySolver);
        vm.expectPartialRevert(StockZap.TooFewShares.selector);
        zap.buyAndBridge{value: 0.02 ether}(_buyPath(), 1e18, avaxUser, block.timestamp + 60);
    }

    function test_buyAndBridge_overBridgeLimitReverts() public {
        // the live limit is large ($250k/day): shrink it on the fork so the test stays cheap
        vm.prank(IEscrowView(ESCROW).owner());
        IEscrowView(ESCROW).setLimit(NVDA, 0.5e18);
        (uint128 perDay,,) = IEscrowView(ESCROW).limits(NVDA);
        // enough ETH for well over the per-transfer (daily) limit
        uint256 eth = (uint256(perDay) * 2 * 0.09 ether) / 1e18;
        vm.prank(relaySolver);
        vm.expectPartialRevert(bytes4(keccak256("OverTransferLimit(uint256,uint256)")));
        zap.buyAndBridge{value: eth}(_buyPath(), 1, avaxUser, block.timestamp + 60);
    }

    function test_buyAndBridge_checks() public {
        vm.startPrank(relaySolver);
        vm.expectRevert(StockZap.Expired.selector);
        zap.buyAndBridge{value: 0.01 ether}(_buyPath(), 1, avaxUser, block.timestamp - 1);
        vm.expectRevert(StockZap.BadPath.selector);
        zap.buyAndBridge{value: 0.01 ether}(abi.encodePacked(USDG, FEE, NVDA), 1, avaxUser, block.timestamp);
        vm.expectRevert(StockZap.BadPath.selector);
        zap.buyAndBridge{value: 0.01 ether}(abi.encodePacked(WETH, NVDA), 1, avaxUser, block.timestamp);
        vm.expectRevert(StockZap.BadArgs.selector);
        zap.buyAndBridge{value: 0.01 ether}(_buyPath(), 1, address(0), block.timestamp);
        vm.expectRevert(); // StockEscrow: Unsupported (WETH → USDG ends in a non-stock)
        zap.buyAndBridge{value: 0.01 ether}(abi.encodePacked(WETH, FEE, USDG), 1, avaxUser, block.timestamp);
        vm.stopPrank();
    }

    function _giveNvda(address to, uint256 amount) internal {
        vm.prank(NVDA_WETH_POOL);
        IERC20(NVDA).transfer(to, amount);
    }

    function test_sellAndBridge_paysEth() public {
        address seller = makeAddr("seller");
        address payTo = makeAddr("relayDepositAddress");
        _giveNvda(seller, 0.1e18);
        vm.startPrank(seller);
        IERC20(NVDA).approve(address(zap), 0.1e18);
        uint256 out = zap.sellAndBridge(NVDA, 0.1e18, _sellPath(), 0.005 ether, payTo, block.timestamp + 60);
        vm.stopPrank();
        assertEq(payTo.balance, out);
        assertGt(out, 0.008 ether); // 0.1 NVDA ≈ $23.5 ≈ 0.0087 ETH
        assertEq(IERC20(NVDA).balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }

    function test_sellAndBridgeWithPermit() public {
        (address seller, uint256 key) = makeAddrAndKey("permitSeller");
        _giveNvda(seller, 0.05e18);
        uint256 deadline = block.timestamp + 60;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                seller,
                address(zap),
                0.05e18,
                IPermitToken(NVDA).nonces(seller),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", IPermitToken(NVDA).DOMAIN_SEPARATOR(), structHash)));
        vm.prank(seller);
        uint256 out = zap.sellAndBridgeWithPermit(NVDA, 0.05e18, _sellPath(), 1, seller, deadline, v, r, s);
        assertEq(seller.balance, out);
        assertGt(out, 0);
    }

    function test_sell_slippageAndPathChecks() public {
        address seller = makeAddr("seller2");
        _giveNvda(seller, 0.05e18);
        vm.startPrank(seller);
        IERC20(NVDA).approve(address(zap), type(uint256).max);
        vm.expectRevert(); // Uniswap: Too little received
        zap.sellAndBridge(NVDA, 0.05e18, _sellPath(), 1 ether, seller, block.timestamp);
        vm.expectRevert(StockZap.BadPath.selector);
        zap.sellAndBridge(NVDA, 0.05e18, _buyPath(), 1, seller, block.timestamp);
        vm.stopPrank();
    }

    function test_receiveOnlyFromWeth() public {
        vm.prank(relaySolver);
        (bool ok,) = address(zap).call{value: 1}("");
        assertFalse(ok);
    }
}
