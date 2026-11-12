// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookLaunchpadV2} from "./HookLaunchpadV2.sol";
import {PartnerFeeModule} from "./modules/PartnerFeeModule.sol";

/// @title PlayableSplitBuyer
/// @notice One transaction that buys a partner's house its fixed stake in one of the partner's launches and
///         gives the caller everything they paid beyond it: `floorTokens` to `house`, the rest to
///         `msg.sender`, both on the launch's bonding curve, both paid for by the caller.
///
///   Why this needs a contract at all: a curve buy always delivers to `msg.sender`, and a launched token
///   cannot be transferred before it graduates (HookTokenV2 reverts with CurvePhaseTransfer), so a launcher
///   has no way to hand the house its stake. `HookLaunchpadV2.buyWithQuoteFor` is the one path that pays
///   from `msg.sender` and delivers to another address, and it is open to the callers the launchpad's owner
///   trusts. This contract is meant to be one of them, and it is deliberately small:
///     - it only ever names `house` or `msg.sender` as the buyer, never an address from its input;
///     - it only touches tokens whose PartnerFeeModule config carries `partnerId`, which only the hook can
///       write, at launch, so the token is always a real launch of that partner;
///     - it never holds the launched token and leaves no quote behind: whatever of the caller's `total` the
///       launchpad didn't pull (the buy that completes the curve takes only what it needs) goes back to
///       the caller in the same transaction;
///     - the house's stake is bought first, at the lowest price of the curve, and the launchpad itself
///       enforces the floor (`minTokensOut`), so a wrong number here cannot shortchange the house.
///
///   The owner (the Safe) can move the house address and the floor; neither changes a launch that already
///   happened, since the tokens are delivered in this transaction. It can also `rescue` tokens sent here by
///   mistake (a split buy itself never leaves any).
contract PlayableSplitBuyer is Ownable {
    using SafeERC20 for IERC20;

    HookLaunchpadV2 public immutable launchpad;
    PartnerFeeModule public immutable partnerFee;
    /// @notice The quote asset the partner's launches use (an ERC-20: `buyWithQuoteFor` refuses native AVAX).
    IERC20 public immutable quote;
    /// @notice The partner whose launches this contract serves (PartnerFeeModule id).
    bytes32 public immutable partnerId;

    /// @notice Where the floor goes: the partner's own wallet (or a contract that can hold the token).
    address public house;
    /// @notice Tokens the house gets from a split buy, whatever the caller spends beyond it.
    uint256 public floorTokens;

    uint16 private constant BPS = 10_000;
    /// @dev A floor of more than this would be a fat finger: a quarter of the curve is already far past the
    ///      5% of supply these launches are for.
    uint256 public constant MAX_FLOOR_TOKENS = 200_000_000 ether;
    /// @notice The house may end up with at most this much over the floor (curve rounding, and the two-wei
    ///         cushion the gross-up carries); past that the transaction reverts rather than quietly spending
    ///         more of the caller's quote on the floor.
    uint16 public constant MAX_OVERSHOOT_BPS = 100;

    error NotPartnerLaunch();
    error CurveClosed();
    error GuardActive();
    error FloorTooLarge();
    error BelowFloor(uint256 needed);
    error Overshoot(uint256 got);
    error BadConfig();

    event Split(
        address indexed token,
        address indexed buyer,
        uint256 floorSpent,
        uint256 floorTokens,
        uint256 restSpent,
        uint256 restTokens
    );
    event HouseSet(address house);
    event FloorSet(uint256 floorTokens);
    event Refund(address indexed buyer, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        HookLaunchpadV2 _launchpad,
        PartnerFeeModule _partnerFee,
        IERC20 _quote,
        bytes32 _partnerId,
        address _house,
        uint256 _floorTokens,
        address _owner
    ) Ownable(_owner) {
        if (
            address(_launchpad) == address(0) || address(_partnerFee) == address(0) || address(_quote) == address(0)
                || _partnerId == bytes32(0)
        ) revert BadConfig();
        launchpad = _launchpad;
        partnerFee = _partnerFee;
        quote = _quote;
        partnerId = _partnerId;
        _setHouse(_house);
        _setFloor(_floorTokens);
    }

    // ---------------------------------------------------------------- owner

    function setHouse(address _house) external onlyOwner {
        _setHouse(_house);
    }

    function setFloorTokens(uint256 _floorTokens) external onlyOwner {
        _setFloor(_floorTokens);
    }

    /// @notice Sends `amount` of `token` held by this contract to `to` (tokens sent here by mistake).
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert BadConfig();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    function _setHouse(address _house) internal {
        if (_house == address(0)) revert BadConfig();
        house = _house;
        emit HouseSet(_house);
    }

    function _setFloor(uint256 _floorTokens) internal {
        if (_floorTokens == 0 || _floorTokens > MAX_FLOOR_TOKENS) revert FloorTooLarge();
        floorTokens = _floorTokens;
        emit FloorSet(_floorTokens);
    }

    // ---------------------------------------------------------------- split buy

    /// @notice Quote the floor costs on `token`'s curve right now, including the launchpad's fees and the
    ///         partner hook's share — what `splitBuy` spends on the house before buying the caller's part.
    function quoteFloor(address token) external view returns (uint256) {
        (HookLaunchpadV2.Launch memory l, uint16 partnerBps) = _launchOf(token);
        return _floorCost(l, partnerBps);
    }

    /// @notice Buys the house its floor and the caller the rest, with `total` of the quote asset (approve
    ///         this contract for it first).
    /// @param minTokensOutRest Floor for the caller's own part; the house's part is always at least
    ///        `floorTokens`, whatever is passed here.
    /// @dev `total` must be either exactly the floor cost or enough over it to buy at least one more token:
    ///      a leftover too small to buy anything makes the launchpad revert on slippage, and the whole
    ///      transaction with it (nothing is left behind). If a buy completes the curve, the launchpad pulls
    ///      only what it needed and the rest of `total` is sent back to the caller (`Refund`); the event's
    ///      `restSpent` is what was actually spent on the caller's part.
    function splitBuy(address token, uint256 total, uint256 minTokensOutRest)
        external
        returns (uint256 floorSpent, uint256 floorGot, uint256 restGot)
    {
        (HookLaunchpadV2.Launch memory l, uint16 partnerBps) = _launchOf(token);
        floorSpent = _floorCost(l, partnerBps);
        if (total < floorSpent) revert BelowFloor(floorSpent);

        // Anything already here (sent by mistake) is not the caller's: only what this call leaves over is refunded.
        uint256 held = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), total);
        quote.forceApprove(address(launchpad), total);

        uint256 floor = floorTokens;
        address to = house;
        uint256 before = IERC20(token).balanceOf(to);
        launchpad.buyWithQuoteFor(token, floorSpent, floor, to);
        floorGot = IERC20(token).balanceOf(to) - before;
        if (floorGot > floor + (floor * MAX_OVERSHOOT_BPS) / BPS) revert Overshoot(floorGot);

        uint256 rest = total - floorSpent;
        // The floor buy itself can't complete the curve with room to spare (`_floorCost` refuses a floor past
        // what's left), but if it lands exactly on the end there is nothing left to buy: refund the rest.
        if (rest > 0 && !launchpad.getLaunch(token).complete) {
            uint256 mine = IERC20(token).balanceOf(msg.sender);
            launchpad.buyWithQuoteFor(token, rest, minTokensOutRest, msg.sender);
            restGot = IERC20(token).balanceOf(msg.sender) - mine;
        }
        quote.forceApprove(address(launchpad), 0);
        uint256 left = quote.balanceOf(address(this)) - held;
        if (left > 0) {
            quote.safeTransfer(msg.sender, left);
            emit Refund(msg.sender, left);
            rest = rest > left ? rest - left : 0;
        }
        emit Split(token, msg.sender, floorSpent, floorGot, rest, restGot);
    }

    // ---------------------------------------------------------------- internals

    /// @dev The launch record of one of this partner's tokens, with the partner hook's share, or a revert.
    function _launchOf(address token) internal view returns (HookLaunchpadV2.Launch memory l, uint16 partnerBps) {
        bytes32 id;
        (id, partnerBps) = partnerFee.partnerOf(token);
        if (id != partnerId) revert NotPartnerLaunch();
        l = launchpad.getLaunch(token);
        if (l.quote != address(quote)) revert NotPartnerLaunch();
        if (l.complete) revert CurveClosed();
        // A per-block buy cap would stop the second of our two buys; the anti-snipe tax is priced in below.
        if (l.maxBuyPerBlock != 0 && l.guardEndBlock != 0 && block.number < l.guardEndBlock) revert GuardActive();
    }

    /// @dev What the floor costs on the live curve, the way HookLaunchpadV2._buy reads it: the constant
    ///      product gives the net quote for the tokens, then the core fees (protocol + creator, plus the
    ///      anti-snipe tax while the guard is on) and the partner hook's cut — both taken from the gross
    ///      input — are added back. Two wei cover the contract's own flooring.
    function _floorCost(HookLaunchpadV2.Launch memory l, uint16 partnerBps) internal view returns (uint256) {
        uint256 floor = floorTokens;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        bool guard = l.guardEndBlock != 0 && block.number < l.guardEndBlock;
        if (floor >= y || floor > launchpad.CURVE_SUPPLY() - l.tokensSold) revert FloorTooLarge();
        uint256 net = Math.mulDiv(x, floor, y - floor, Math.Rounding.Ceil);
        uint256 keep =
            BPS - launchpad.PROTOCOL_FEE_BPS() - l.creatorFeeBps - (guard ? l.snipeTaxBps : 0) - partnerBps;
        return Math.mulDiv(net, BPS, keep, Math.Rounding.Ceil) + 2;
    }
}
