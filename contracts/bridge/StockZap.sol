// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Uniswap SwapRouter02 (IV3SwapRouter): no deadline in the params, the zap checks it.
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 is IERC20 {
    function withdraw(uint256) external;
}

interface IStockEscrow {
    function lock(address originToken, uint256 amount, address recipient) external returns (uint64 nonce);
    function escrowedShares(address originToken) external view returns (uint256);
}

/// @title StockZap
/// @notice Robinhood Chain helper that lets a user buy or sell a real stock token and cross the AvaxHook
///         bridge in one transaction, with their own funds. Immutable, no owner, holds nothing between
///         calls.
///
///   Buy:  `buyAndBridge{value: eth}(path, minShares, avaxRecipient, deadline)` swaps all the ETH into the
///         stock on Uniswap v3 (`path` = WETH → … → stock), locks everything it got in StockEscrow for
///         `avaxRecipient` (the bridge then mints the same shares of mNVDA etc. on Avalanche) and
///         reverts unless at least `minShares` were locked. Meant to be the destination call of a Relay
///         cross-chain request (AVAX on Avalanche → ETH here → this call), so nothing in it depends on
///         `msg.sender`: buying on someone's behalf only ever benefits them.
///
///   Sell: `sellAndBridge(stock, amount, path, minEthOut, to, deadline)` pulls the caller's stock (after a
///         StockEscrow release), swaps it to ETH on Uniswap v3 (`path` = stock → … → WETH) and sends the
///         ETH to `to`: the caller's own address, or a Relay deposit address that bridges it back to
///         AVAX on Avalanche. `sellAndBridgeWithPermit` does the same with an EIP-2612 permit.
contract StockZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IV3SwapRouter public immutable router;
    IStockEscrow public immutable escrow;
    IWETH9 public immutable weth;

    event Bought(
        address indexed stock,
        address indexed avaxRecipient,
        address indexed sender,
        uint256 ethIn,
        uint256 amount,
        uint256 shares,
        uint64 nonce
    );
    event Sold(address indexed stock, address indexed seller, address indexed to, uint256 amount, uint256 ethOut);

    error Expired();
    error BadPath();
    error BadArgs();
    error TooFewShares(uint256 shares, uint256 minShares);
    error EthTransferFailed();

    constructor(IV3SwapRouter _router, IStockEscrow _escrow, IWETH9 _weth) {
        if (address(_router) == address(0) || address(_escrow) == address(0) || address(_weth) == address(0)) revert BadArgs();
        router = _router;
        escrow = _escrow;
        weth = _weth;
    }

    /// @notice Only WETH unwrapping sends ETH here.
    receive() external payable {
        if (msg.sender != address(weth)) revert BadArgs();
    }

    // ---------------------------------------------------------------- buy

    /// @notice Swap all `msg.value` ETH into the stock at the end of `path` and lock it for `avaxRecipient`.
    /// @return nonce the StockEscrow lock nonce (the bridge's message id)
    /// @return shares bridged shares credited (= mStock minted on Avalanche)
    function buyAndBridge(bytes calldata path, uint256 minShares, address avaxRecipient, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint64 nonce, uint256 shares)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0 || avaxRecipient == address(0) || minShares == 0) revert BadArgs();
        (address tokenIn, address stock) = _ends(path);
        if (tokenIn != address(weth)) revert BadPath();

        uint256 before = IERC20(stock).balanceOf(address(this));
        // SwapRouter02 wraps the ETH it receives when the path starts with WETH.
        router.exactInput{value: msg.value}(
            IV3SwapRouter.ExactInputParams({path: path, recipient: address(this), amountIn: msg.value, amountOutMinimum: 0})
        );
        uint256 amount = IERC20(stock).balanceOf(address(this)) - before;

        // `minShares` is checked on what the escrow credits, so rounding and the share rate count too.
        IERC20(stock).forceApprove(address(escrow), amount);
        uint256 sharesBefore = escrow.escrowedShares(stock);
        nonce = escrow.lock(stock, amount, avaxRecipient);
        shares = escrow.escrowedShares(stock) - sharesBefore;
        IERC20(stock).forceApprove(address(escrow), 0);
        if (shares < minShares) revert TooFewShares(shares, minShares);

        emit Bought(stock, avaxRecipient, msg.sender, msg.value, amount, shares, nonce);
    }

    // ---------------------------------------------------------------- sell

    /// @notice Sell `amount` of the caller's `stock` for ETH along `path` (stock → … → WETH), paid to `to`.
    function sellAndBridge(address stock, uint256 amount, bytes calldata path, uint256 minEthOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        return _sell(stock, amount, path, minEthOut, to, deadline);
    }

    /// @notice `sellAndBridge` with an EIP-2612 permit for `amount`. A permit that was already used (e.g.
    ///         front-run) is ignored as long as the allowance is there.
    function sellAndBridgeWithPermit(
        address stock,
        uint256 amount,
        bytes calldata path,
        uint256 minEthOut,
        address to,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 ethOut) {
        try IERC20Permit(stock).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        return _sell(stock, amount, path, minEthOut, to, deadline);
    }

    function _sell(address stock, uint256 amount, bytes calldata path, uint256 minEthOut, address to, uint256 deadline)
        internal
        returns (uint256 ethOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amount == 0 || to == address(0) || minEthOut == 0) revert BadArgs();
        (address tokenIn, address tokenOut) = _ends(path);
        if (tokenIn != stock || tokenOut != address(weth)) revert BadPath();

        uint256 before = IERC20(stock).balanceOf(address(this));
        IERC20(stock).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(stock).balanceOf(address(this)) - before; // multiplier tokens may round

        IERC20(stock).forceApprove(address(router), received);
        uint256 wethOut = router.exactInput(
            IV3SwapRouter.ExactInputParams({path: path, recipient: address(this), amountIn: received, amountOutMinimum: minEthOut})
        );
        IERC20(stock).forceApprove(address(router), 0);

        weth.withdraw(wethOut);
        ethOut = wethOut;
        (bool ok,) = to.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
        emit Sold(stock, msg.sender, to, received, ethOut);
    }

    // ---------------------------------------------------------------- internals

    /// @dev First and last token of a Uniswap v3 path (token, fee(3 bytes), token, …).
    function _ends(bytes calldata path) internal pure returns (address first, address last) {
        uint256 n = path.length;
        if (n < 43 || (n - 20) % 23 != 0) revert BadPath();
        first = address(bytes20(path[0:20]));
        last = address(bytes20(path[n - 20:n]));
    }
}
