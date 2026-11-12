// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {HookLaunchpad} from "../HookLaunchpad.sol";
import {AvaxHookRouter} from "../AvaxHookRouter.sol";
import {QuoteRegistry} from "../QuoteRegistry.sol";
import {StockGateway} from "../bridge/StockGateway.sol";
import {BridgedStock} from "../bridge/BridgedStock.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title StockOrders
/// @notice Async "pay USDC / USDt / AVAX, get bridged stock" orders on Avalanche, and the reverse.
///
///   Buy: the user's payment sits here until a solver fills the order. The solver bridges the value
///   to Robinhood Chain, buys the real stock, locks it in StockEscrow and gets the bridged token
///   (mNVDA, …) minted here; it then calls `fill`, which pulls that mStock from the solver, hands it
///   to the recipient (or swaps it into the launch token paired with it) and only then pays the solver
///   the escrowed payment. Bridged supply always equals escrowed stock: this contract never mints.
///
///   Sell: the user's mStock (or launch token, sold for mStock at open) sits here; the solver pays the
///   recipient in the chosen pay token and receives the mStock, which it burns to release the stock.
///
///   Nothing is custodied by the solver: an order that is not filled by its deadline can be cancelled
///   by anyone and refunds its owner in full. `minOut` is the user's real price protection; `quote` /
///   `quoteSell` are only indicative (feed prices minus SPREAD_BPS and the protocol fee).
///
///   Protocol fee (`feeBps`, ≤ MAX_FEE_BPS, to `feeRecipient`) is charged only when an order is FILLED,
///   so a cancel always refunds 100%:
///   - Buys: taken out of the escrowed payment. The solver is paid `amountIn - fee`, `feeRecipient`
///     gets `fee = amountIn * feeBps / 10_000`. The user's `minOut` (mStock / launch tokens) is
///     unaffected: the solver simply sizes its delivery for the smaller reimbursement.
///   - Sells: paid by the solver on top of the payout. `fill(id, amount)`: `amount` is what the
///     recipient receives (net, checked against `minOut`), the solver delivers
///     `amount + fee` with `fee = amount * feeBps / (10_000 - feeBps)` (= feeBps of the gross).
///   In both directions `fill`'s `amount` is what the user side receives and `minOut` is net of every
///   fee. A fee change only moves the solver's economics, never what an open order can receive.
contract StockOrders is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    enum Kind {
        BuyStock,
        BuyLaunch,
        SellStock,
        SellLaunch
    }

    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Order {
        address owner;
        address recipient;
        Kind kind;
        Status status;
        address payToken; // USDC/USDt or address(0) = native AVAX
        address mToken; // bridged stock, e.g. mNVDA
        address launchToken; // launch paired with mToken, or address(0)
        uint128 amountIn; // buys: payToken in; sells: launchToken or mToken in
        uint128 stockAmount; // sells: mStock held for the order; buys: mStock delivered at fill
        uint128 minOut; // BuyStock: min mStock; BuyLaunch: min launch tokens; Sell*: min payToken out
        uint128 amountOut; // set at fill
        uint64 deadline;
    }

    uint16 public constant SPREAD_BPS = 50; // solver spread in quotes, indicative only — minOut is the real protection
    uint16 public constant MAX_FEE_BPS = 100; // protocol fee hard cap: 1%
    uint256 public constant MIN_DURATION = 2 minutes;
    uint256 public constant MAX_DURATION = 2 hours;
    uint256 internal constant BPS = 10_000;

    HookLaunchpad public immutable launchpad;
    AvaxHookRouter public immutable router;
    QuoteRegistry public immutable registry;
    StockGateway public immutable gateway;

    mapping(address => bool) public isSolver;
    /// @notice Protocol fee in bps, charged at fill (see the contract notes).
    uint16 public feeBps = 30;
    address public feeRecipient;
    /// @notice Cancel refunds that could not be pushed to their owner (a contract rejecting AVAX, a
    ///         blocklisted token holder, …): owner => token (address(0) = AVAX) => amount.
    mapping(address => mapping(address => uint256)) public pendingRefunds;
    mapping(uint256 => Order) internal _orders;
    uint256 internal _count; // ids start at 1; getOrder(0) is an empty order

    event OrderOpened(
        uint256 indexed id,
        address indexed owner,
        Kind kind,
        address payToken,
        address mToken,
        address launchToken,
        uint256 amountIn,
        uint256 stockAmount,
        uint256 minOut,
        uint64 deadline
    );
    /// @param fee protocol fee in the pay token (buys: out of amountIn; sells: on top of amountOut).
    event OrderFilled(uint256 indexed id, address indexed solver, uint256 stockAmount, uint256 amountOut, uint256 fee);
    event OrderCancelled(uint256 indexed id);
    event SolverSet(address indexed solver, bool on);
    event FeeSet(uint16 feeBps);
    event FeeRecipientSet(address indexed recipient);
    event RefundDeferred(uint256 indexed id, address indexed owner, address token, uint256 amount);
    event RefundClaimed(address indexed owner, address token, address to, uint256 amount);
    event HookCreditsClaimed(address indexed currency, address indexed to, uint256 amount);

    error BadArgs();
    error BadDeadline();
    error NotAllowed();
    error NotSolver();
    error NotOpen();
    error Expired();
    error NotExpired();
    error Slippage();
    error BadValue();
    error TransferFailed();
    error FeeTooHigh();

    constructor(
        HookLaunchpad _launchpad,
        AvaxHookRouter _router,
        QuoteRegistry _registry,
        StockGateway _gateway,
        address _owner,
        address _feeRecipient
    ) Ownable(_owner) {
        if (_feeRecipient == address(0)) revert BadArgs();
        launchpad = _launchpad;
        router = _router;
        registry = _registry;
        gateway = _gateway;
        feeRecipient = _feeRecipient;
        emit FeeSet(feeBps);
        emit FeeRecipientSet(_feeRecipient);
    }

    modifier onlySolver() {
        if (!isSolver[msg.sender]) revert NotSolver();
        _;
    }

    function setSolver(address solver, bool on) external onlyOwner {
        isSolver[solver] = on;
        emit SolverSet(solver, on);
    }

    function setFee(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert BadArgs();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Withdraws what the AvaxHook owes this contract in `currency` to `to`. Post-graduation
    ///         BuyLaunch fills swap through AvaxHookRouter with this contract as the payer, so pot wins
    ///         (Nth-buy / last-buyer) and similar credits are booked to StockOrders, not to the order's
    ///         user (the deployed router has no "buy for" entry point). The owner forwards them to the
    ///         user(s) who earned them (see the hook's PotWon events and the matching OrderFilled).
    function claimHookCredits(Currency currency, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert BadArgs();
        amount = launchpad.hook().claimable(address(this), currency);
        launchpad.hook().claim(currency, to);
        emit HookCreditsClaimed(Currency.unwrap(currency), to, amount);
    }

    // ---------------------------------------------------------------- open

    /// @notice Pay `amountIn` of `payToken` (address(0) = AVAX, sent as value) for `mToken`, or for
    ///         `launchToken` (a launch quoted in `mToken`) when it is set.
    function openBuy(
        address payToken,
        uint128 amountIn,
        address mToken,
        address launchToken,
        uint128 minOut,
        uint64 deadline,
        address recipient
    ) external payable nonReentrant returns (uint256 id) {
        _checkPair(payToken, mToken, launchToken, amountIn, minOut, deadline);
        // Curve-phase launch tokens may only reach EOAs (no pools/venues before graduation).
        if (launchToken != address(0) && recipient.code.length != 0) revert BadArgs();
        if (payToken == address(0)) {
            if (msg.value != amountIn) revert BadValue();
        } else {
            if (msg.value != 0) revert BadValue();
            _pullExact(payToken, msg.sender, amountIn);
        }
        id = _store(launchToken == address(0) ? Kind.BuyStock : Kind.BuyLaunch, payToken, mToken, launchToken, amountIn, 0, minOut, deadline, recipient);
    }

    /// @notice Sell `amountIn` of `mToken`, or of `launchToken` (sold for mStock right now, at least
    ///         `minStockFromSell`), for at least `minOut` of `payToken` paid at fill.
    function openSell(
        address mToken,
        address launchToken,
        uint128 amountIn,
        uint128 minStockFromSell,
        address payToken,
        uint128 minOut,
        uint64 deadline,
        address recipient
    ) external nonReentrant returns (uint256 id) {
        _checkPair(payToken, mToken, launchToken, amountIn, minOut, deadline);
        uint256 stock;
        if (launchToken == address(0)) {
            stock = _pullExact(mToken, msg.sender, amountIn);
        } else {
            stock = _sellLaunch(mToken, launchToken, amountIn, minStockFromSell);
        }
        if (stock == 0) revert Slippage();
        id = _store(
            launchToken == address(0) ? Kind.SellStock : Kind.SellLaunch,
            payToken,
            mToken,
            launchToken,
            amountIn,
            stock.toUint128(),
            minOut,
            deadline,
            recipient
        );
    }

    // ---------------------------------------------------------------- fill / cancel

    /// @notice Solver fills an open order. Buys: `amount` mStock is pulled from the solver (approve
    ///         first), delivered (or swapped into the launch token) and the solver is paid the order's
    ///         payment minus the protocol fee. Sells: the recipient gets `amount` of the pay token
    ///         (net, ≥ minOut); the solver delivers `amount + fillFee(id, amount)` (AVAX as value,
    ///         ERC-20 by approval) and receives the held mStock.
    function fill(uint256 id, uint128 amount) external payable nonReentrant onlySolver {
        Order storage o = _orders[id];
        if (o.status != Status.Open) revert NotOpen();
        if (block.timestamp > o.deadline) revert Expired();
        o.status = Status.Filled;
        uint256 out;
        uint256 fee = _fee(o, amount);

        if (o.kind == Kind.BuyStock || o.kind == Kind.BuyLaunch) {
            if (msg.value != 0) revert BadValue();
            if (amount == 0) revert Slippage();
            _pullExact(o.mToken, msg.sender, amount);
            if (o.kind == Kind.BuyStock) {
                if (amount < o.minOut) revert Slippage();
                IERC20(o.mToken).safeTransfer(o.recipient, amount);
                out = amount;
            } else {
                out = _buyLaunch(o.mToken, o.launchToken, amount, o.minOut, o.recipient);
            }
            o.stockAmount = amount;
            o.amountOut = out.toUint128();
            _pay(o.payToken, msg.sender, o.amountIn - fee);
        } else {
            if (amount < o.minOut) revert Slippage();
            if (o.payToken == address(0)) {
                if (msg.value != amount + fee) revert BadValue();
            } else {
                if (msg.value != 0) revert BadValue();
                _pullExact(o.payToken, msg.sender, amount + fee);
            }
            _pay(o.payToken, o.recipient, amount);
            out = amount;
            o.amountOut = amount;
            IERC20(o.mToken).safeTransfer(msg.sender, o.stockAmount);
        }
        _pay(o.payToken, feeRecipient, fee);
        emit OrderFilled(id, msg.sender, o.stockAmount, out, fee);
    }

    /// @notice After the deadline anyone can cancel an unfilled order; the owner gets their funds back.
    ///         If the owner can't receive them (e.g. a contract that rejects AVAX), the refund is
    ///         credited to `pendingRefunds` instead, so a cancel can never be blocked; the owner then
    ///         pulls it to any address with `claimRefund`.
    function cancel(uint256 id) external nonReentrant {
        Order storage o = _orders[id];
        if (o.status != Status.Open) revert NotOpen();
        if (block.timestamp <= o.deadline) revert NotExpired();
        o.status = Status.Cancelled;
        emit OrderCancelled(id);
        bool buy = o.kind == Kind.BuyStock || o.kind == Kind.BuyLaunch;
        address token = buy ? o.payToken : o.mToken;
        uint256 amount = buy ? o.amountIn : o.stockAmount;
        if (amount != 0 && !_tryPay(token, o.owner, amount)) {
            pendingRefunds[o.owner][token] += amount;
            emit RefundDeferred(id, o.owner, token, amount);
        }
    }

    /// @notice Withdraw a deferred cancel refund of `token` (address(0) = AVAX) to `to`.
    function claimRefund(address token, address to) external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender][token];
        if (amount == 0 || to == address(0)) revert BadArgs();
        pendingRefunds[msg.sender][token] = 0;
        emit RefundClaimed(msg.sender, token, to, amount);
        _pay(token, to, amount);
    }

    // ---------------------------------------------------------------- views

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    function orderCount() external view returns (uint256) {
        return _count;
    }

    /// @notice Protocol fee (pay token) that `fill(id, amount)` charges right now: buys take it out of
    ///         the payment; sells add it on top of `amount`, so a solver sends `amount + fillFee`.
    function fillFee(uint256 id, uint128 amount) external view returns (uint256) {
        return _fee(_orders[id], amount);
    }

    /// @notice Indicative mStock for `amountIn` of `payToken`, at feed prices minus the protocol fee
    ///         and SPREAD_BPS. Also the amount a solver delivers to fill such a buy.
    function quote(address payToken, uint256 amountIn, address mToken) external view returns (uint256 stockOut) {
        (uint256 pPay, uint256 dPay) = _price(payToken);
        (uint256 pStock, uint256 dStock) = _price(mToken);
        amountIn -= (amountIn * feeBps) / BPS;
        stockOut = Math.mulDiv(Math.mulDiv(amountIn, pPay, pStock), 10 ** dStock, 10 ** dPay);
        stockOut = (stockOut * (BPS - SPREAD_BPS)) / BPS;
    }

    /// @notice Indicative `payToken` the recipient gets for `stockIn` mStock, at feed prices minus
    ///         SPREAD_BPS and the protocol fee. Also the net `amount` a solver fills such a sell with.
    function quoteSell(address mToken, uint256 stockIn, address payToken) external view returns (uint256 payOut) {
        (uint256 pStock, uint256 dStock) = _price(mToken);
        (uint256 pPay, uint256 dPay) = _price(payToken);
        payOut = Math.mulDiv(Math.mulDiv(stockIn, pStock, pPay), 10 ** dPay, 10 ** dStock);
        payOut = (payOut * (BPS - SPREAD_BPS)) / BPS;
        payOut -= (payOut * feeBps) / BPS;
    }

    // ---------------------------------------------------------------- internals

    function _checkPair(address payToken, address mToken, address launchToken, uint128 amountIn, uint128 minOut, uint64 deadline)
        internal
        view
    {
        if (amountIn == 0 || minOut == 0 || payToken == mToken) revert BadArgs();
        if (deadline < block.timestamp + MIN_DURATION || deadline > block.timestamp + MAX_DURATION) revert BadDeadline();
        (bool payOk,,) = registry.quotes(payToken);
        (bool stockOk,,) = registry.quotes(mToken);
        if (!payOk || !stockOk || !_isBridged(mToken)) revert NotAllowed();
        if (launchToken != address(0) && launchpad.quoteOf(launchToken) != mToken) revert NotAllowed();
    }

    /// @dev A StockGateway bridged stock: the gateway's token for its own origin is this address.
    function _isBridged(address mToken) internal view returns (bool) {
        if (mToken.code.length == 0) return false;
        try BridgedStock(mToken).originToken() returns (address origin) {
            return address(gateway.bridged(origin)) == mToken;
        } catch {
            return false;
        }
    }

    function _store(
        Kind kind,
        address payToken,
        address mToken,
        address launchToken,
        uint128 amountIn,
        uint128 stockAmount,
        uint128 minOut,
        uint64 deadline,
        address recipient
    ) internal returns (uint256 id) {
        if (recipient == address(0)) recipient = msg.sender;
        id = ++_count;
        _orders[id] = Order({
            owner: msg.sender,
            recipient: recipient,
            kind: kind,
            status: Status.Open,
            payToken: payToken,
            mToken: mToken,
            launchToken: launchToken,
            amountIn: amountIn,
            stockAmount: stockAmount,
            minOut: minOut,
            amountOut: 0,
            deadline: deadline
        });
        emit OrderOpened(id, msg.sender, kind, payToken, mToken, launchToken, amountIn, stockAmount, minOut, deadline);
    }

    /// @dev Swaps `amount` mStock into the launch token for `to`: on the curve before graduation
    ///      (curve tokens can only leave the launchpad, so it delivers straight to `to`), in the pool
    ///      after. Unused mStock (a curve-completing buy) goes to `to` too.
    function _buyLaunch(address mToken, address launchToken, uint256 amount, uint256 minOut, address to)
        internal
        returns (uint256 out)
    {
        uint256 stockBefore = IERC20(mToken).balanceOf(address(this));
        HookLaunchpad.Launch memory l = launchpad.getLaunch(launchToken);
        if (!l.graduated) {
            if (to.code.length != 0) revert BadArgs();
            uint256 before = IERC20(launchToken).balanceOf(to);
            IERC20(mToken).forceApprove(address(launchpad), amount);
            launchpad.buyWithQuoteFor(launchToken, amount, minOut, to);
            IERC20(mToken).forceApprove(address(launchpad), 0);
            out = IERC20(launchToken).balanceOf(to) - before;
        } else {
            uint256 before = IERC20(launchToken).balanceOf(address(this));
            IERC20(mToken).forceApprove(address(router), amount);
            router.buy(launchToken, amount, minOut, address(0), block.timestamp);
            IERC20(mToken).forceApprove(address(router), 0);
            out = IERC20(launchToken).balanceOf(address(this)) - before;
            IERC20(launchToken).safeTransfer(to, out);
        }
        if (out < minOut || out == 0) revert Slippage();
        uint256 spent = stockBefore - IERC20(mToken).balanceOf(address(this));
        if (amount > spent) IERC20(mToken).safeTransfer(to, amount - spent);
    }

    /// @dev Sells the owner's launch tokens for mStock held by this contract.
    function _sellLaunch(address mToken, address launchToken, uint256 amountIn, uint256 minStock) internal returns (uint256 stock) {
        uint256 before = IERC20(mToken).balanceOf(address(this));
        HookLaunchpad.Launch memory l = launchpad.getLaunch(launchToken);
        if (!l.graduated) {
            // Curve-phase tokens may only move to the launchpad: deposit there, then sell the deposit.
            IERC20(launchToken).safeTransferFrom(msg.sender, address(launchpad), amountIn);
            launchpad.sellDeposited(launchToken, amountIn, minStock);
        } else {
            _pullExact(launchToken, msg.sender, amountIn);
            IERC20(launchToken).forceApprove(address(router), amountIn);
            router.sell(launchToken, amountIn, minStock, block.timestamp);
        }
        stock = IERC20(mToken).balanceOf(address(this)) - before;
        if (stock < minStock) revert Slippage();
    }

    function _fee(Order storage o, uint256 amount) internal view returns (uint256) {
        if (o.kind == Kind.BuyStock || o.kind == Kind.BuyLaunch) return (uint256(o.amountIn) * feeBps) / BPS;
        return (amount * feeBps) / (BPS - feeBps);
    }

    function _price(address token) internal view returns (uint256 usd, uint256 dec) {
        (, uint8 d,) = registry.quotes(token);
        usd = registry.usdPrice(token); // reverts if unknown or stale
        dec = d;
    }

    /// @dev Pulls exactly `amount` (no fee-on-transfer); returns it.
    function _pullExact(address token, address from, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert TransferFailed();
        return amount;
    }

    /// @dev Best-effort transfer that reports failure instead of reverting. AVAX is sent with all gas
    ///      but without copying return data; ERC-20s follow SafeERC20's success rules.
    function _tryPay(address token, address to, uint256 amount) internal returns (bool ok) {
        if (token == address(0)) {
            assembly ("memory-safe") {
                ok := call(gas(), to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        bytes memory ret;
        (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        return ret.length == 0 ? token.code.length != 0 : (ret.length >= 32 && abi.decode(ret, (bool)));
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
