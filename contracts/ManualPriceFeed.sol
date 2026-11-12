// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ManualPriceFeed
/// @notice A Chainlink-compatible USD price pushed by a keeper, for quote assets that have no
///         Chainlink feed on Avalanche (tokenized stocks, Avalanche coins). 18 decimals by default so
///         micro-priced tokens (e.g. $0.00000015) keep full precision. QuoteRegistry rejects it once
///         it is older than 26 hours, so an unattended feed simply stops new launches for that asset.
///         It sets the starting curve parameters of new launches and prices StockOrders conversions;
///         curve trading never reads it.
///
///   On-chain limits: `setPrice` (keeper or owner) may move the answer by at most `maxMoveBps` per
///   update and at most once every `minInterval`, so a leaked keeper key can only walk the price
///   slowly. Larger moves (a real gap, or a long keeper outage) go through the owner's `forcePrice`.
contract ManualPriceFeed is Ownable2Step {
    uint256 internal constant BPS = 10_000;

    string public description;
    uint8 public immutable decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _round;

    /// @notice Hot key allowed to push bounded updates (the owner can too).
    address public keeper;
    /// @notice Largest move one `setPrice` may make, relative to the current answer.
    uint16 public maxMoveBps = 2_500;
    /// @notice Minimum time between two `setPrice` updates.
    uint32 public minInterval = 5 minutes;

    event PriceSet(int256 answer, uint256 updatedAt);
    event KeeperSet(address keeper);
    event LimitsSet(uint16 maxMoveBps, uint32 minInterval);

    error BadPrice();
    error NotKeeper();
    error TooSoon();
    error MoveTooLarge();

    constructor(address _owner, string memory _description, uint8 _decimals, int256 initial) Ownable(_owner) {
        description = _description;
        decimals = _decimals;
        _set(initial);
    }

    /// @notice Bounded update for the keeper (or the owner).
    function setPrice(int256 answer) external {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        if (answer <= 0) revert BadPrice();
        if (block.timestamp < _updatedAt + minInterval) revert TooSoon();
        uint256 last = uint256(_answer);
        uint256 next = uint256(answer);
        uint256 diff = next > last ? next - last : last - next;
        if (diff * BPS > last * maxMoveBps) revert MoveTooLarge();
        _set(answer);
    }

    /// @notice Unbounded update: the owner's override for moves the limits refuse.
    function forcePrice(int256 answer) external onlyOwner {
        _set(answer);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setLimits(uint16 _maxMoveBps, uint32 _minInterval) external onlyOwner {
        if (_maxMoveBps == 0) revert BadPrice();
        maxMoveBps = _maxMoveBps;
        minInterval = _minInterval;
        emit LimitsSet(_maxMoveBps, _minInterval);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }

    function _set(int256 answer) internal {
        if (answer <= 0) revert BadPrice();
        _answer = answer;
        _updatedAt = block.timestamp;
        _round += 1;
        emit PriceSet(answer, block.timestamp);
    }
}
