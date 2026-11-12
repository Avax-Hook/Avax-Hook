// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title SignedPriceHub
/// @notice Many SignedPriceFeed-style USD prices in one contract. QuoteRegistry needs one Chainlink-style feed
///         address per quote (`latestRoundData()` takes no asset), so every price gets a tiny clone,
///         `HubPriceFeed`, that reads its price from here; the prices, the signer and the owner live here once.
///
///   Signatures are exactly those of SignedPriceFeed: EIP-712 `PriceUpdate(int256 answer,uint64 timestamp)`
///   under the domain ("AvaxHook SignedPriceFeed", "1", chainId, <the feed clone>), so the existing price signer
///   signs for a clone as it does for a standalone feed, and a signature fits one feed on one chain only. A
///   signature must be at most `MAX_SIGNATURE_AGE` old, not dated in the future and strictly newer than the
///   feed's current price, so old prices can't be replayed or used to roll a feed back.
///
///   `update` (also reachable through the clone's own `update`, so launch flows written for SignedPriceFeed
///   keep working) applies one price; `updateBatch` applies many in one transaction for the keeper and skips,
///   rather than reverts on, an entry that is no longer newer (someone refreshed that feed first). The owner
///   creates feeds, can override a price with `forcePrice` and rotates the signer.
contract SignedPriceHub is Ownable2Step {
    bytes32 public constant PRICE_UPDATE_TYPEHASH = keccak256("PriceUpdate(int256 answer,uint64 timestamp)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("AvaxHook SignedPriceFeed");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    /// @notice Oldest signature `update` accepts.
    uint256 public constant MAX_SIGNATURE_AGE = 10 minutes;
    /// @notice Every clone reports 18 decimals.
    uint8 public constant DECIMALS = 18;

    struct Price {
        int256 answer;
        uint64 updatedAt;
        uint80 round;
    }

    struct Update {
        address feed;
        int256 answer;
        uint64 timestamp;
        bytes signature;
    }

    /// @notice Code every feed clone runs.
    address public immutable feedImplementation;
    /// @notice Off-chain key whose signatures `update` accepts.
    address public signer;
    /// @notice Every feed this hub created, in order.
    address[] public feeds;
    mapping(address feed => bool) public isFeed;
    mapping(address feed => Price) internal _prices;

    event FeedCreated(address indexed feed, string description);
    event PriceSet(address indexed feed, int256 answer, uint256 updatedAt);
    event SignerSet(address signer);

    error BadPrice();
    error BadSignature();
    error StaleSignature();
    error NotNewer();
    error FutureTimestamp();
    error UnknownFeed();

    constructor(address _owner, address _signer) Ownable(_owner) {
        feedImplementation = address(new HubPriceFeed());
        signer = _signer;
        emit SignerSet(_signer);
    }

    // ---------------------------------------------------------------- owner

    /// @notice New feed clone (e.g. "mPLTR / USD") starting at `initial`, dated now.
    function createFeed(string calldata description, int256 initial) external onlyOwner returns (address feed) {
        feed = Clones.clone(feedImplementation);
        HubPriceFeed(feed).initialize(description);
        isFeed[feed] = true;
        feeds.push(feed);
        emit FeedCreated(feed, description);
        _set(feed, initial, block.timestamp);
    }

    /// @notice Owner override, dated now.
    function forcePrice(address feed, int256 answer) external onlyOwner {
        if (!isFeed[feed]) revert UnknownFeed();
        _set(feed, answer, block.timestamp);
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerSet(_signer);
    }

    // ---------------------------------------------------------------- updates (anyone)

    /// @notice Submit one price signed by `signer` for `feed`.
    function update(address feed, int256 answer, uint64 timestamp, bytes calldata signature) external {
        if (!isFeed[feed]) revert UnknownFeed();
        if (timestamp <= _prices[feed].updatedAt) revert NotNewer();
        _apply(feed, answer, timestamp, signature);
    }

    /// @notice Submit many signed prices. An entry no newer than its feed's price is skipped; any other
    ///         bad entry reverts the whole batch. Returns how many were applied.
    function updateBatch(Update[] calldata updates) external returns (uint256 applied) {
        for (uint256 i; i < updates.length; ++i) {
            Update calldata u = updates[i];
            if (!isFeed[u.feed]) revert UnknownFeed();
            if (u.timestamp <= _prices[u.feed].updatedAt) continue;
            _apply(u.feed, u.answer, u.timestamp, u.signature);
            ++applied;
        }
    }

    // ---------------------------------------------------------------- views

    function feedCount() external view returns (uint256) {
        return feeds.length;
    }

    /// @notice Chainlink-style round of `feed` (what its clone's `latestRoundData` returns).
    function roundData(address feed) external view returns (uint80, int256, uint256, uint256, uint80) {
        Price memory p = _prices[feed];
        return (p.round, p.answer, p.updatedAt, p.updatedAt, p.round);
    }

    /// @notice The EIP-712 domain separator signatures for `feed` are made under.
    function domainSeparator(address feed) public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, feed));
    }

    // ---------------------------------------------------------------- internal

    /// @dev Caller checked `isFeed[feed]` and that `timestamp` is newer than the feed's price.
    function _apply(address feed, int256 answer, uint64 timestamp, bytes calldata signature) internal {
        if (answer <= 0) revert BadPrice();
        // Never ahead of the block: QuoteRegistry rejects a feed dated in the future (updatedAt >
        // block.timestamp), so accepting one would block launches until the chain caught up.
        if (timestamp > block.timestamp) revert FutureTimestamp();
        if (uint256(timestamp) + MAX_SIGNATURE_AGE < block.timestamp) revert StaleSignature();
        bytes32 structHash = keccak256(abi.encode(PRICE_UPDATE_TYPEHASH, answer, timestamp));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(feed), structHash));
        (address rec, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || rec == address(0) || rec != signer) revert BadSignature();
        _set(feed, answer, timestamp);
    }

    function _set(address feed, int256 answer, uint256 timestamp) internal {
        if (answer <= 0) revert BadPrice();
        Price storage p = _prices[feed];
        p.answer = answer;
        p.updatedAt = uint64(timestamp);
        p.round += 1;
        emit PriceSet(feed, answer, timestamp);
    }
}

/// @title HubPriceFeed
/// @notice One quote's Chainlink-style USD feed, a minimal clone created by its SignedPriceHub. It stores
///         only its description; the price, the signer and the owner are the hub's. Its `update` matches
///         SignedPriceFeed's, so a launch flow that refreshes a SignedPriceFeed refreshes this the same way.
contract HubPriceFeed {
    /// @notice The hub that created this feed (an immutable of the implementation, so shared by its clones).
    SignedPriceHub public immutable hub;
    string public description;
    bool internal _initialized;

    error InitializeDenied();

    constructor() {
        hub = SignedPriceHub(msg.sender);
        _initialized = true; // the implementation itself is never a feed
    }

    /// @dev Called once by the hub, in the transaction that creates the clone.
    function initialize(string calldata _description) external {
        if (msg.sender != address(hub) || _initialized) revert InitializeDenied();
        _initialized = true;
        description = _description;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return hub.roundData(address(this));
    }

    /// @notice Same call as SignedPriceFeed.update: a price signed by the hub's signer for this feed.
    function update(int256 answer, uint64 timestamp, bytes calldata signature) external {
        hub.update(address(this), answer, timestamp, signature);
    }

    function signer() external view returns (address) {
        return hub.signer();
    }

    function owner() external view returns (address) {
        return hub.owner();
    }
}
