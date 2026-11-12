// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BridgeAttestor
/// @notice Shared core of the AvaxHook stock bridge: a validator set that attests to transfers seen
///         on the other chain, M-of-N EIP-712 signature checks, replay protection, per-token rate
///         limits and a guardian that can pause instantly.
///
///   A transfer is identified by (source chain, source contract, nonce). The signed payload also
///   binds the destination chain and contract, so a signature is valid exactly once, in exactly one
///   place. Signatures must be sorted by signer address (strictly ascending), which rules out
///   duplicates without a seen-set.
///
///   Roles:
///   - owner     (a multisig behind a timelock): validator set, limits, token routes, guardian.
///   - guardian  (a hot key or bot): can pause, cannot unpause or move funds.
abstract contract BridgeAttestor is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;
    using SafeCast for uint256;

    struct Transfer {
        uint256 srcChainId;
        address srcContract;
        uint64 nonce;
        uint256 dstChainId;
        address dstContract;
        address originToken; // the stock token on Robinhood Chain: one id for both sides
        address recipient;
        /// @dev Bridged shares, not origin-token units: 1 share = 1 bridged token (mNVDA) on Avalanche
        ///      and `StockEscrow.originPerShare(originToken)` origin units on Robinhood Chain. Share
        ///      counts don't change when the stock splits, so a message signed before a split still
        ///      settles correctly after it.
        uint256 shares;
    }

    /// @dev Token-bucket rate limit: `used` is the outstanding usage as of `updatedAt` and drains
    ///      linearly at `perDay` per day. At most `perDay` can come in at once, and over any interval
    ///      of length T at most `perDay + perDay * T / 1 days`. Unlike a fixed window that resets at
    ///      its edge, two full days' worth can never pass back to back.
    struct Limit {
        uint128 perDay; // capacity and refill per day; 0 = route closed
        uint128 used; // outstanding usage at `updatedAt`
        uint64 updatedAt;
    }

    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(uint256 srcChainId,address srcContract,uint64 nonce,uint256 dstChainId,address dstContract,address originToken,address recipient,uint256 shares)"
    );
    uint256 public constant MAX_VALIDATORS = 32;
    /// @notice Never fewer than three validators: no single key, and no owner-only set, can attest.
    uint256 public constant MIN_VALIDATORS = 3;

    /// @notice The chain and contract on the other side this contract accepts transfers from.
    uint256 public immutable remoteChainId;
    address public remoteContract;

    address[] internal _validators;
    mapping(address => bool) public isValidator;
    uint256 public threshold;
    address public guardian;

    /// @notice Outgoing transfer counter (this side is the source).
    uint64 public outboundNonce;
    /// @dev Incoming transfers already executed, keyed by (source contract, nonce), so a redeployed
    ///      remote that restarts its nonces can't collide with history.
    mapping(bytes32 => bool) internal _processed;
    /// @notice Daily limits per origin token, for incoming transfers, in shares (split-invariant).
    mapping(address => Limit) public limits;

    event ValidatorsSet(address[] validators, uint256 threshold);
    event RemoteSet(address remoteContract);
    event GuardianSet(address guardian);
    event LimitSet(address indexed originToken, uint128 perDay);

    error BadValidators();
    error BadSignatures();
    error AlreadyProcessed();
    error WrongRoute();
    error LimitExceeded(uint256 requested, uint256 available);
    error NotGuardian();
    error ZeroAmount();
    error OverTransferLimit(uint256 amount, uint256 max);
    error BadRecipient();

    constructor(string memory name, address _owner, uint256 _remoteChainId) Ownable(_owner) EIP712(name, "1") {
        remoteChainId = _remoteChainId;
    }

    // ---------------------------------------------------------------- admin

    function setValidators(address[] calldata newValidators, uint256 _threshold) external onlyOwner {
        uint256 n = newValidators.length;
        // A majority threshold over at least three keys: a minority of compromised keys can never move funds.
        if (n < MIN_VALIDATORS || n > MAX_VALIDATORS || _threshold <= n / 2 || _threshold > n) revert BadValidators();
        for (uint256 i; i < _validators.length; ++i) isValidator[_validators[i]] = false;
        address prev;
        for (uint256 i; i < n; ++i) {
            address v = newValidators[i];
            if (v <= prev) revert BadValidators(); // sorted, unique, non-zero
            isValidator[v] = true;
            prev = v;
        }
        _validators = newValidators;
        threshold = _threshold;
        emit ValidatorsSet(newValidators, _threshold);
    }

    function setRemote(address _remoteContract) external onlyOwner {
        remoteContract = _remoteContract;
        emit RemoteSet(_remoteContract);
    }

    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    function setLimit(address originToken, uint128 perDay) external onlyOwner {
        Limit storage l = limits[originToken];
        // settle the drain at the old rate first, so a new rate never applies retroactively
        l.used = _outstanding(l).toUint128();
        l.updatedAt = uint64(block.timestamp);
        l.perDay = perDay;
        emit LimitSet(originToken, perDay);
    }

    /// @notice Guardian or owner can stop the bridge at once; only the owner can restart it.
    function pause() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------- views

    function validators() external view returns (address[] memory) {
        return _validators;
    }

    function hashTransfer(Transfer calldata t) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    TRANSFER_TYPEHASH,
                    t.srcChainId,
                    t.srcContract,
                    t.nonce,
                    t.dstChainId,
                    t.dstContract,
                    t.originToken,
                    t.recipient,
                    t.shares
                )
            )
        );
    }

    function isProcessed(address srcContract, uint64 nonce) public view returns (bool) {
        return _processed[keccak256(abi.encode(srcContract, nonce))];
    }

    /// @notice What can come in right now for `originToken` (refills continuously at `perDay` per day).
    function available(address originToken) public view returns (uint256) {
        Limit storage l = limits[originToken];
        uint256 out = _outstanding(l);
        return l.perDay > out ? l.perDay - out : 0;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Checks route, replay, signatures and the daily limit, then marks the transfer done.
    function _accept(Transfer calldata t, bytes[] calldata signatures) internal {
        if (t.srcChainId != remoteChainId || t.srcContract != remoteContract) revert WrongRoute();
        if (t.dstChainId != block.chainid || t.dstContract != address(this)) revert WrongRoute();
        if (t.shares == 0 || t.recipient == address(0)) revert ZeroAmount();
        bytes32 id = keccak256(abi.encode(t.srcContract, t.nonce));
        if (_processed[id]) revert AlreadyProcessed();

        bytes32 digest = hashTransfer(t);
        uint256 n = signatures.length;
        // threshold is 0 until setValidators runs: refuse rather than accept an empty signature set.
        if (threshold == 0 || n < threshold) revert BadSignatures();
        address prev;
        for (uint256 i; i < n; ++i) {
            address signer = digest.recover(signatures[i]);
            if (signer <= prev || !isValidator[signer]) revert BadSignatures();
            prev = signer;
        }

        _processed[id] = true;
        _consume(t.originToken, t.shares);
    }

    function _consume(address originToken, uint256 amount) internal {
        Limit storage l = limits[originToken];
        uint256 out = _outstanding(l);
        uint256 avail = l.perDay > out ? l.perDay - out : 0;
        if (amount > avail) revert LimitExceeded(amount, avail);
        l.used = (out + amount).toUint128(); // <= perDay
        l.updatedAt = uint64(block.timestamp);
    }

    /// @dev Usage still counted against the bucket now: `used` minus what drained since `updatedAt`.
    function _outstanding(Limit storage l) internal view returns (uint256) {
        uint256 used = l.used;
        if (used == 0) return 0;
        uint256 drained = (block.timestamp - l.updatedAt) * uint256(l.perDay) / 1 days;
        return used > drained ? used - drained : 0;
    }

    /// @dev Outgoing checks shared by lock and burn. Both sides are configured with the same per-token
    ///      daily limit, so a transfer the other side could never accept in one day is refused here
    ///      instead of getting stuck. The recipient can't be either bridge contract.
    function _checkOutgoing(address originToken, uint256 shares, address recipient) internal view {
        if (shares == 0 || recipient == address(0)) revert ZeroAmount();
        if (remoteContract == address(0)) revert WrongRoute();
        if (recipient == address(this) || recipient == remoteContract) revert BadRecipient();
        uint256 max = limits[originToken].perDay;
        if (shares > max) revert OverTransferLimit(shares, max);
    }

    function _nextNonce() internal returns (uint64) {
        return ++outboundNonce;
    }
}
