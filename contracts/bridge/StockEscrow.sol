// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BridgeAttestor} from "./BridgeAttestor.sol";

/// @title StockEscrow
/// @notice Robinhood Chain side of the AvaxHook stock bridge. Holds the real Robinhood stock tokens
///         (NVDA, TSLA, …) that back the bridged tokens on Avalanche.
///
///   Robinhood → Avalanche: `lock` takes the stock token into escrow, converts the amount received to
///   bridged SHARES at the token's current `originPerShare` and emits `Locked`; validators attest and
///   StockGateway mints that many shares (mNVDA) on Avalanche.
///   Avalanche → Robinhood: StockGateway burns shares and emits `BurnedForRelease`; validators attest
///   and `release` pays out `shares × originPerShare` of the real token.
///
///   Splits. Every cross-chain message is in shares, and a share is a fixed claim on the escrow. If a
///   corporate action changes the escrow's token balance (a balance-rebasing 2:1 split doubles it, a
///   1:10 reverse split cuts it to a tenth), the owner applies the same ratio to `originPerShare`, so
///   each share redeems for exactly its slice of the new balance. Nothing on Avalanche changes: mNVDA
///   supply, holders, pools and in-flight messages stay valid, and no one has to be touched.
///   (Robinhood's current tokens express splits through `uiMultiplier()` and leave raw balances
///   alone; then the rate simply stays at 1e18. This covers an implementation that rebases balances.)
///
///   Backing invariant, enforced on every rate change and by construction everywhere else:
///     escrowedShares[token] × originPerShare(token) / 1e18  ≤  token.balanceOf(escrow)
///   lock credits shares for what actually arrived (rounded down), release pays shares at the current
///   rate (rounded down) and `applySplit` refuses any rate the balance can't cover, so the owner can't
///   use it to drain the escrow. During a corporate action the token is paused here (guardian or
///   owner), so nothing locks or releases at a stale rate between the token's change and the update.
contract StockEscrow is BridgeAttestor {
    using SafeERC20 for IERC20;

    /// @notice originPerShare before any split: 1 share = 1 origin token.
    uint256 public constant RATE_ONE = 1e18;
    /// @notice A single `applySplit` moves the rate by at most this factor either way (fat-finger guard).
    uint256 public constant MAX_SPLIT_FACTOR = 1_000;
    /// @notice Tokens with a balance multiplier can deliver a few wei less than sent; more is a short transfer.
    uint256 public constant MAX_ROUNDING = 1_000;

    /// @notice Stock tokens that can cross. Only plain ERC-20s; Robinhood can still pause its tokens.
    mapping(address => bool) public supported;
    /// @notice Bridged shares outstanding per token (= bridged supply on Avalanche plus in-flight).
    mapping(address => uint256) public escrowedShares;
    /// @notice Paused per token around corporate actions: no lock or release until the owner resumes it.
    mapping(address => bool) public tokenPaused;
    /// @dev Origin units per share, 1e18-scaled; 0 means RATE_ONE.
    mapping(address => uint256) internal _rate;

    event Locked(
        uint64 indexed nonce,
        address indexed originToken,
        address indexed from,
        address recipient,
        uint256 shares,
        uint256 amount,
        uint256 dstChainId
    );
    event Released(uint64 indexed srcNonce, address indexed originToken, address indexed recipient, uint256 shares, uint256 amount);
    event ReleaseRedirected(
        uint64 indexed srcNonce, address indexed originToken, address indexed oldRecipient, address newRecipient, uint256 shares, uint256 amount
    );
    event TokenSupported(address indexed originToken, bool supported);
    event TokenPaused(address indexed originToken, bool paused);
    event SplitApplied(
        address indexed originToken, uint256 num, uint256 den, uint256 oldRate, uint256 newRate, uint256 balance, uint256 shares
    );

    error Unsupported();
    error ShortTransfer();
    error TokenIsPaused();
    error NotPausedForSplit();
    error BadSplit();
    error Undercollateralized(uint256 required, uint256 balance);

    /// @param _avalancheChainId 43114 on mainnet.
    constructor(address _owner, uint256 _avalancheChainId) BridgeAttestor("AvaxHook StockEscrow", _owner, _avalancheChainId) {}

    // ---------------------------------------------------------------- admin

    function setSupported(address originToken, bool on) external onlyOwner {
        supported[originToken] = on;
        emit TokenSupported(originToken, on);
    }

    /// @notice Stop one stock (ahead of a split, or on anything odd). Guardian or owner.
    function pauseToken(address originToken) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        tokenPaused[originToken] = true;
        emit TokenPaused(originToken, true);
    }

    function unpauseToken(address originToken) external onlyOwner {
        tokenPaused[originToken] = false;
        emit TokenPaused(originToken, false);
    }

    /// @notice Apply a corporate action that changed the escrow's balance of `originToken` by
    ///         `num/den` (2:1 split: 2,1; 1:10 reverse split: 1,10). Only while the token is paused here,
    ///         and only to a rate the current balance fully covers. Also the tool to socialise a loss
    ///         (e.g. an issuer burn from the escrow) pro rata: any lower rate is always covered.
    function applySplit(address originToken, uint256 num, uint256 den) external onlyOwner {
        if (!tokenPaused[originToken]) revert NotPausedForSplit();
        if (num == 0 || den == 0 || num > MAX_SPLIT_FACTOR * den || den > MAX_SPLIT_FACTOR * num) revert BadSplit();
        uint256 oldRate = originPerShare(originToken);
        uint256 newRate = Math.mulDiv(oldRate, num, den);
        if (newRate == 0) revert BadSplit();
        uint256 shares = escrowedShares[originToken];
        uint256 bal = IERC20(originToken).balanceOf(address(this));
        uint256 required = Math.mulDiv(shares, newRate, RATE_ONE);
        if (required > bal) revert Undercollateralized(required, bal);
        _rate[originToken] = newRate;
        emit SplitApplied(originToken, num, den, oldRate, newRate, bal, shares);
    }

    // ---------------------------------------------------------------- views

    /// @notice Origin-token units one share redeems for, 1e18-scaled (1e18 until the first split).
    function originPerShare(address originToken) public view returns (uint256) {
        uint256 r = _rate[originToken];
        return r == 0 ? RATE_ONE : r;
    }

    /// @notice Shares `amount` origin units lock into right now (rounded down).
    function toShares(address originToken, uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, RATE_ONE, originPerShare(originToken));
    }

    /// @notice Origin units `shares` release right now (rounded down).
    function toAmount(address originToken, uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, originPerShare(originToken), RATE_ONE);
    }

    /// @notice Origin units the escrow must hold to redeem every outstanding share.
    function backingRequired(address originToken) public view returns (uint256) {
        return toAmount(originToken, escrowedShares[originToken]);
    }

    // ---------------------------------------------------------------- bridge

    /// @notice Escrow `amount` of a stock token and send the matching bridged shares to `recipient`
    ///         on Avalanche (1:1 until the first split). Approve this contract first.
    function lock(address originToken, uint256 amount, address recipient) external nonReentrant whenNotPaused returns (uint64 nonce) {
        if (!supported[originToken]) revert Unsupported();
        if (tokenPaused[originToken]) revert TokenIsPaused();
        _checkOutgoing(originToken, toShares(originToken, amount), recipient);

        uint256 before = IERC20(originToken).balanceOf(address(this));
        IERC20(originToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(originToken).balanceOf(address(this)) - before;
        // Shares are credited for what arrived, never for what was asked, so backing holds whatever the
        // token does; only multiplier rounding (a few wei) is tolerated as a shortfall.
        if (received > amount || received + MAX_ROUNDING < amount) revert ShortTransfer();
        uint256 shares = toShares(originToken, received);
        if (shares == 0) revert ZeroAmount();

        escrowedShares[originToken] += shares;
        nonce = _nextNonce();
        emit Locked(nonce, originToken, msg.sender, recipient, shares, received, remoteChainId);
    }

    /// @notice Release escrowed tokens for a burn the validators saw on Avalanche. Anyone can submit.
    ///         Pays the burned shares at the current rate. (A paused origin token, here or at Robinhood,
    ///         makes this revert until it is lifted; the relayer retries.)
    function release(Transfer calldata t, bytes[] calldata signatures) external nonReentrant whenNotPaused {
        uint256 amount = _settle(t, signatures);
        if (amount != 0) _pay(t.originToken, t.recipient, amount);
        emit Released(t.nonce, t.originToken, t.recipient, t.shares, amount);
    }

    /// @notice Owner (timelocked) escape hatch for a release that can never reach its recipient, e.g. the
    ///         issuer blocklisted that address: pays the same validator-attested transfer to `newRecipient`.
    ///         Goes through the same `_accept` as `release`, so a nonce is paid at most once either way.
    ///         It first tries the original recipient; only if that transfer fails is it redirected, so the
    ///         owner can't divert a release that would have gone through.
    function redirectRelease(Transfer calldata t, bytes[] calldata signatures, address newRecipient)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        if (newRecipient == address(0) || newRecipient == address(this)) revert BadRecipient();
        uint256 amount = _settle(t, signatures);
        address to = t.recipient;
        if (amount != 0) {
            uint256 before = IERC20(t.originToken).balanceOf(to);
            (bool ok, bytes memory ret) = t.originToken.call(abi.encodeCall(IERC20.transfer, (to, amount)));
            if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) {
                if (IERC20(t.originToken).balanceOf(to) - before + MAX_ROUNDING < amount) revert ShortTransfer();
            } else {
                to = newRecipient;
                _pay(t.originToken, to, amount);
                emit ReleaseRedirected(t.nonce, t.originToken, t.recipient, to, t.shares, amount);
            }
        }
        emit Released(t.nonce, t.originToken, to, t.shares, amount);
    }

    /// @dev Checks and consumes the attested transfer, debits its shares; returns the origin units owed.
    function _settle(Transfer calldata t, bytes[] calldata signatures) internal returns (uint256) {
        if (tokenPaused[t.originToken]) revert TokenIsPaused();
        _accept(t, signatures);
        escrowedShares[t.originToken] -= t.shares; // reverts if more would leave than was ever escrowed
        return toAmount(t.originToken, t.shares);
    }

    function _pay(address token, address to, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        // a token that started taking a fee on transfer must not under-deliver
        if (IERC20(token).balanceOf(to) - before + MAX_ROUNDING < amount) revert ShortTransfer();
    }
}
