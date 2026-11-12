// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AvaxHookRouterV2} from "./AvaxHookRouterV2.sol";
import {AvaxHookZap} from "./AvaxHookZap.sol";
import {HookLaunchpadV2} from "./HookLaunchpadV2.sol";

/// @title AvaxHookLimitOrdersV2
/// @notice Limit orders on graduated v2 pools. A maker escrows the input here with a limit (the least they
///         accept out, which fixes the price); anyone (in practice the AvaxHook keeper) fills the order
///         through AvaxHookRouterV2 once the pool pays at least that much. The contract only ever trades an
///         order at or above its own limit, so a filler can choose when, never the price.
///   Fee: `feeBps` of the quote side (taken from the input on buys, from the output on sells), fixed per
///   order when it is placed, paid to `feeRecipient` on fill. Cancelled and expired orders pay nothing.
///   Trader identity: the router names this contract as the trader, so like the zap it only takes tokens
///   whose every module is identity-neutral (`zap.zappable`, the owner's list on the zap).
///   Curve-phase tokens can't be escrowed (HookTokenV2 only moves to or from the launchpad before
///   graduation), so orders open on graduation.
///   Keeper fee: every order also pays `keeperFee` in AVAX (fixed per order when placed). Whoever fills it, or
///   returns it after expiry, earns that fee, so each order pays its own gas and dust orders cost their maker,
///   not the keeper. A maker who cancels gets it back.
///   AVAX owed to a maker that refuses it is kept as `owed` for `withdraw`, so a fill or refund never blocks.
///
///   V2 (same ABI as v1, plus `owedToken`, `withdrawToken`, `escrowed`, `owedTotal`, `sweep`):
///   - An ERC-20 payout that fails (a maker blacklisted by USDC/USDt, a token rule refusing the receiver) is
///     kept as `owedToken[account][asset]` instead of reverting, so `cancel` and `fill` never block on the
///     recipient; the account pulls it with `withdrawToken(asset, to)` to any address (`asset = 0` also pulls
///     native `owed` to `to`). v1 reverted, so a blacklisted maker's order could never leave Open.
///   - The contract tracks what it owes per asset (`escrowed`: open orders' inputs and keeper fees; `owedTotal`:
///     credited payouts), and the owner can `sweep` only the excess above both: stray tokens or AVAX sent here
///     by mistake, never a maker's escrow or credit.
contract AvaxHookLimitOrdersV2 is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address internal constant NATIVE = address(0);
    uint256 internal constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 100;
    uint88 public constant MAX_KEEPER_FEE = 0.1 ether;

    AvaxHookRouterV2 public immutable router;
    HookLaunchpadV2 public immutable launchpad;
    AvaxHookZap public immutable zap;

    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Order {
        address maker;
        uint40 expiry; // last second it can fill
        uint16 feeBps;
        Status status;
        address token;
        bool isBuy; // buy: quote in, tokens out; sell: tokens in, quote out
        uint88 keeperFee; // AVAX paid with the order, to whoever fills or returns it (back to a maker who cancels)
        uint128 amountIn; // escrowed input (buys: before the fee)
        uint128 minOut; // the limit: least the maker receives (buys: tokens; sells: quote after the fee)
    }

    Order[] internal _orders;
    mapping(address => uint256[]) internal _byMaker;

    uint16 public feeBps;
    uint88 public keeperFee;
    address public feeRecipient;
    bool public paused;
    mapping(address => uint256) public owed;
    /// @notice ERC-20 payouts a recipient could not receive, kept for `withdrawToken`.
    mapping(address account => mapping(address asset => uint256)) public owedToken;
    /// @notice Per asset (0 = AVAX): what open orders hold here (inputs, and keeper fees in AVAX).
    mapping(address asset => uint256) public escrowed;
    /// @notice Per asset (0 = AVAX): credited payouts not withdrawn yet (`owed` + every `owedToken`).
    mapping(address asset => uint256) public owedTotal;

    event OrderPlaced(
        uint256 indexed id,
        address indexed maker,
        address indexed token,
        bool isBuy,
        uint256 amountIn,
        uint256 minOut,
        uint256 expiry,
        uint256 keeperFee
    );
    event OrderFilled(uint256 indexed id, address indexed filler, uint256 amountOut, uint256 fee);
    event OrderCancelled(uint256 indexed id);
    event ConfigSet(uint16 feeBps, uint88 keeperFee, address feeRecipient, bool paused);
    event Owed(address indexed account, uint256 amount);
    event OwedToken(address indexed account, address indexed asset, uint256 amount);
    event Withdrawn(address indexed account, address indexed asset, address to, uint256 amount);
    event Swept(address indexed asset, address indexed to, uint256 amount);

    error Paused();
    error NotOrderable();
    error BadOrder();
    error NotOpen();
    error Expired();
    error NotMaker();
    error Slippage();
    error TransferFailed();
    error NothingOwed();
    error Reserved();

    constructor(AvaxHookZap _zap, uint16 _feeBps, uint88 _keeperFee, address _feeRecipient, address owner_) Ownable(owner_) {
        zap = _zap;
        router = _zap.router();
        launchpad = _zap.launchpad();
        _setConfig(_feeBps, _keeperFee, _feeRecipient, false);
    }

    receive() external payable {}

    // ---------------------------------------------------------------- owner

    function setConfig(uint16 _feeBps, uint88 _keeperFee, address _feeRecipient, bool _paused) external onlyOwner {
        _setConfig(_feeBps, _keeperFee, _feeRecipient, _paused);
    }

    /// @notice Sends `amount` of `asset` (0 = AVAX) that nobody is owed (sent here by mistake) to `to`. Never
    ///         touches escrow or credited payouts: at most the balance above `escrowed + owedTotal`.
    function sweep(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || amount > sweepable(asset)) revert Reserved();
        emit Swept(asset, to, amount);
        if (asset == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _setConfig(uint16 _feeBps, uint88 _keeperFee, address _feeRecipient, bool _paused) internal {
        if (_feeBps > MAX_FEE_BPS || _keeperFee > MAX_KEEPER_FEE || _feeRecipient == address(0)) revert BadOrder();
        (feeBps, keeperFee, feeRecipient, paused) = (_feeBps, _keeperFee, _feeRecipient, _paused);
        emit ConfigSet(_feeBps, _keeperFee, _feeRecipient, _paused);
    }

    // ---------------------------------------------------------------- makers

    /// @notice Escrows `amountIn` and opens an order. Buys pay the pool's quote (AVAX as value, ERC-20s
    ///         approved here); sells approve the token. `minOut` is the least the maker accepts (buys: tokens
    ///         for `amountIn` less the fee; sells: quote after the fee). Fills until `expiry` (a timestamp).
    ///         `msg.value` also carries `keeperFee` (AVAX buys: amountIn + keeperFee; everything else: keeperFee).
    function place(address token, bool isBuy, uint256 amountIn, uint256 minOut, uint256 expiry)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (paused) revert Paused();
        (bool ok,) = zap.zappable(token);
        if (!ok) revert NotOrderable();
        if (amountIn == 0 || minOut == 0 || expiry <= block.timestamp || expiry > type(uint40).max) revert BadOrder();

        uint88 tip = keeperFee;
        address asset = isBuy ? launchpad.quoteOf(token) : token;
        if (asset == NATIVE) {
            if (msg.value != amountIn + tip) revert BadOrder();
        } else {
            if (msg.value != tip) revert BadOrder();
            // Measured, so a short-arriving transfer escrows only what arrived.
            uint256 b0 = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amountIn);
            amountIn = IERC20(asset).balanceOf(address(this)) - b0;
        }
        if (amountIn > type(uint128).max || minOut > type(uint128).max) revert BadOrder();
        escrowed[asset] += amountIn;
        escrowed[NATIVE] += tip;

        id = _orders.length;
        _orders.push(
            Order({
                maker: msg.sender,
                expiry: uint40(expiry),
                feeBps: feeBps,
                status: Status.Open,
                token: token,
                isBuy: isBuy,
                keeperFee: tip,
                amountIn: uint128(amountIn),
                minOut: uint128(minOut)
            })
        );
        _byMaker[msg.sender].push(id);
        emit OrderPlaced(id, msg.sender, token, isBuy, amountIn, minOut, expiry, tip);
    }

    /// @notice Returns the escrow. The maker can cancel any time and gets the keeper fee back too; anyone can
    ///         return an expired order and earns its keeper fee for doing so.
    function cancel(uint256 id) external nonReentrant {
        Order storage o = _open(id);
        if (msg.sender != o.maker && block.timestamp <= o.expiry) revert NotMaker();
        o.status = Status.Cancelled;
        emit OrderCancelled(id);
        address asset = o.isBuy ? launchpad.quoteOf(o.token) : o.token;
        escrowed[asset] -= o.amountIn;
        escrowed[NATIVE] -= o.keeperFee;
        _pay(asset, o.maker, o.amountIn);
        _pay(NATIVE, msg.sender, o.keeperFee);
    }

    /// @notice AVAX a maker's address refused during a fill or refund.
    function withdraw() external nonReentrant {
        uint256 amount = owed[msg.sender];
        owed[msg.sender] = 0;
        owedTotal[NATIVE] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Pulls what the caller is owed in `asset` to `to` (any address, e.g. when the caller's own
    ///         address is blacklisted by the token). `asset = address(0)` pulls the native `owed`.
    function withdrawToken(address asset, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert TransferFailed();
        if (asset == NATIVE) {
            amount = owed[msg.sender];
            owed[msg.sender] = 0;
        } else {
            amount = owedToken[msg.sender][asset];
            owedToken[msg.sender][asset] = 0;
        }
        if (amount == 0) revert NothingOwed();
        owedTotal[asset] -= amount;
        emit Withdrawn(msg.sender, asset, to, amount);
        if (asset == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    // ---------------------------------------------------------------- fillers

    /// @notice Fills an open order through the router if the pool pays at least its limit. Permissionless:
    ///         the limit is enforced here, so a filler only picks the moment. The filler earns the keeper fee.
    function fill(uint256 id) external nonReentrant returns (uint256 out) {
        if (paused) revert Paused();
        Order storage o = _open(id);
        if (block.timestamp > o.expiry) revert Expired();
        (bool ok,) = zap.zappable(o.token);
        if (!ok) revert NotOrderable();
        o.status = Status.Filled;

        address quote = launchpad.quoteOf(o.token);
        escrowed[o.isBuy ? quote : o.token] -= o.amountIn;
        escrowed[NATIVE] -= o.keeperFee;
        uint256 fee;
        if (o.isBuy) {
            fee = (uint256(o.amountIn) * o.feeBps) / BPS;
            uint256 spend = o.amountIn - fee;
            uint256 t0 = IERC20(o.token).balanceOf(address(this));
            uint256 q0 = _balance(quote);
            if (quote == NATIVE) {
                router.buy{value: spend}(o.token, spend, o.minOut, address(0), block.timestamp, "");
            } else {
                IERC20(quote).forceApprove(address(router), spend);
                router.buy(o.token, spend, o.minOut, address(0), block.timestamp, "");
                IERC20(quote).forceApprove(address(router), 0);
            }
            out = IERC20(o.token).balanceOf(address(this)) - t0;
            if (out < o.minOut) revert Slippage();
            // Whatever of `spend` the pool didn't take (the router refunds it) goes back to the maker.
            uint256 unspent = _balance(quote) + spend - q0;
            _pay(o.token, o.maker, out);
            _pay(quote, o.maker, unspent);
        } else {
            uint256 q0 = _balance(quote);
            uint256 t0 = IERC20(o.token).balanceOf(address(this));
            IERC20(o.token).forceApprove(address(router), o.amountIn);
            router.sell(o.token, o.amountIn, 0, block.timestamp, "");
            IERC20(o.token).forceApprove(address(router), 0);
            uint256 gross = _balance(quote) - q0;
            fee = (gross * o.feeBps) / BPS;
            out = gross - fee;
            if (out < o.minOut) revert Slippage();
            _pay(quote, o.maker, out);
            // A partial fill (the pool hit its price limit) leaves tokens behind: back to the maker.
            uint256 unsold = o.amountIn - (t0 - IERC20(o.token).balanceOf(address(this)));
            _pay(o.token, o.maker, unsold);
        }
        _pay(quote, feeRecipient, fee);
        _pay(NATIVE, msg.sender, o.keeperFee);
        emit OrderFilled(id, msg.sender, out, fee);
    }

    // ---------------------------------------------------------------- views

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function getOrder(uint256 id) external view returns (Order memory) {
        return _orders[id];
    }

    /// @notice Orders `from` .. `from + n - 1` (clipped to the end), for keepers scanning the book.
    function getOrders(uint256 from, uint256 n) external view returns (Order[] memory page) {
        uint256 len = _orders.length;
        if (from >= len) return page;
        if (n > len - from) n = len - from;
        page = new Order[](n);
        for (uint256 i; i < n; ++i) {
            page[i] = _orders[from + i];
        }
    }

    function orderIdsOf(address maker) external view returns (uint256[] memory) {
        return _byMaker[maker];
    }

    /// @notice What `sweep` may move of `asset`: the balance above open escrow and credited payouts.
    function sweepable(address asset) public view returns (uint256) {
        uint256 bal = _balance(asset);
        uint256 reserved = escrowed[asset] + owedTotal[asset];
        return bal > reserved ? bal - reserved : 0;
    }

    // ---------------------------------------------------------------- internals

    function _open(uint256 id) internal view returns (Order storage o) {
        if (id >= _orders.length) revert NotOpen();
        o = _orders[id];
        if (o.status != Status.Open) revert NotOpen();
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == NATIVE ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /// @dev A payout the recipient can't take (AVAX refused, an ERC-20 transfer that reverts or returns false,
    ///      e.g. a USDC/USDt blacklist) is credited (`owed` / `owedToken`) instead of reverting.
    function _pay(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset != NATIVE) {
            if (!_tryTransfer(asset, to, amount)) {
                owedToken[to][asset] += amount;
                owedTotal[asset] += amount;
                emit OwedToken(to, asset, amount);
            }
            return;
        }
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            owed[to] += amount;
            owedTotal[NATIVE] += amount;
            emit Owed(to, amount);
        }
    }

    /// @dev SafeERC20 semantics without the revert: success, and either no return data from a contract or `true`.
    function _tryTransfer(address asset, address to, uint256 amount) internal returns (bool ok) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 rsize;
        uint256 rval;
        assembly ("memory-safe") {
            ok := call(gas(), asset, 0, add(data, 0x20), mload(data), 0, 0x20)
            rsize := returndatasize()
            rval := mload(0)
        }
        if (!ok) return false;
        return rsize == 0 ? asset.code.length > 0 : rval == 1;
    }
}
