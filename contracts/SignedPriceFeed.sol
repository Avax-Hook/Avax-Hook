// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title SignedPriceFeed
/// @notice A Chainlink-compatible USD price for quote assets with no Chainlink feed on Avalanche,
///         updated on a pull model: an off-chain signer signs (answer, timestamp) and anyone, usually
///         the user about to launch, submits it and pays the gas. QuoteRegistry rejects the price once
///         it is older than 26 hours, so an idle feed just needs a fresh signature before the next launch.
///         It sets the starting curve parameters of new launches; curve trading never reads it.
///
///   Signatures are EIP-712 `PriceUpdate(int256 answer,uint64 timestamp)` under the domain
///   ("AvaxHook SignedPriceFeed", "1", chainId, this feed), so a signature only fits one feed on one
///   chain. A signature must be under `MAX_SIGNATURE_AGE` old and strictly newer than the current
///   price, so old prices can't be replayed or used to roll the feed back. The owner can override
///   with `forcePrice` and rotate the signer.
contract SignedPriceFeed is Ownable2Step, EIP712("AvaxHook SignedPriceFeed", "1") {
    bytes32 public constant PRICE_UPDATE_TYPEHASH = keccak256("PriceUpdate(int256 answer,uint64 timestamp)");
    /// @notice Oldest signature `update` accepts.
    uint256 public constant MAX_SIGNATURE_AGE = 10 minutes;

    string public description;
    uint8 public immutable decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _round;

    /// @notice Off-chain key whose signatures `update` accepts.
    address public signer;

    event PriceSet(int256 answer, uint256 updatedAt);
    event SignerSet(address signer);

    error BadPrice();
    error BadSignature();
    error StaleSignature();
    error NotNewer();
    error FutureTimestamp();

    constructor(address _owner, address _signer, string memory _description, uint8 _decimals, int256 initial)
        Ownable(_owner)
    {
        signer = _signer;
        description = _description;
        decimals = _decimals;
        emit SignerSet(_signer);
        _set(initial, block.timestamp);
    }

    /// @notice Submit a price signed by `signer`. Anyone may call.
    function update(int256 answer, uint64 timestamp, bytes calldata signature) external {
        if (answer <= 0) revert BadPrice();
        if (timestamp <= _updatedAt) revert NotNewer();
        // Never ahead of the block: QuoteRegistry rejects a feed dated in the future (updatedAt >
        // block.timestamp), so accepting one would block launches until the chain caught up.
        if (timestamp > block.timestamp) revert FutureTimestamp();
        if (timestamp + MAX_SIGNATURE_AGE < block.timestamp) revert StaleSignature();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(PRICE_UPDATE_TYPEHASH, answer, timestamp)));
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || rec == address(0) || rec != signer) revert BadSignature();
        _set(answer, timestamp);
    }

    /// @notice Owner override, dated now.
    function forcePrice(int256 answer) external onlyOwner {
        _set(answer, block.timestamp);
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerSet(_signer);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }

    function _set(int256 answer, uint256 timestamp) internal {
        if (answer <= 0) revert BadPrice();
        _answer = answer;
        _updatedAt = timestamp;
        _round += 1;
        emit PriceSet(answer, timestamp);
    }
}
