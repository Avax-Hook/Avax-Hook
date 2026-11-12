// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {IAvaxHookV2View, IQuotePrices} from "./HookModuleBase.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title JackpotModule
/// @notice "Quantum jackpot": `bps` of every trade's quote amount (buys: from the input, sells: from the output;
///         curve and pool, every route) fills a pot. Time is cut into rounds of `roundSeconds`. Each qualifying
///         buy gives the buyer tickets equal to the quote it spent in the current round; when a round ends,
///         anyone (the AvaxHook keeper) calls `settle(token)` and one ticket is drawn: its owner takes the whole
///         pot if they still hold at least `minHoldBps` of the supply, else the pot rolls over to the next round.
///   - Qualifying buy: the buyer is known (a curve buy, or a pool buy through the AvaxHook router), it spends at
///     least `minBuy` quote units, and the buyer is not the creator. Aggregator buys pay into the pot but get
///     no tickets. `minBuy` must be worth $1 .. $500 at launch (QuoteRegistry price), so dust can't spam rounds
///     and a creator can't price everyone out.
///   - Tickets: an append-only log of (buyer, cumulative tickets) per round; consecutive buys by the same
///     wallet merge. There is no entry cap (each buy pays for its own log slot), and the draw is a binary
///     search, so nobody can fill a round to lock later buyers out. Splitting buys across wallets doesn't change
///     the odds: tickets follow money.
///   - Randomness: when the round is first touched after its end (a trade or `settle`), the module commits
///     to the next block (`drawBlock`); `settle` needs a later block and uses `blockhash(drawBlock)`, which
///     nobody knew at commit time. If nobody settles within 256 blocks the hash is gone and the draw is
///     committed again to a fresh block. This is not a verifiable random function: the producer of the draw
///     block can grind or withhold it, and once the hash exists anyone can compute the winner, so with a slow
///     settle a winner who sold can buy back in time to qualify. Keep pots meme-sized; settle promptly.
///   - Holding check: the winner's balance at `settle` minus whatever it received in the settle block itself
///     (onTransfer records the amount per block), so neither a flash top-up nor a dust gift in that block
///     changes the outcome.
///   - Rounds: a new round starts at the first trade (or settle) after the old one ends. While a closed round
///     waits for its draw, the current round keeps running (it closes once the previous draw is settled).
///     Fees that arrive between a round's end and its settle are in the pot the winner takes.
///   - Payout: the pot is this module's claim in the hook (checked against the hook's books first,
///     LedgerModuleBase); the winner is paid with `transferClaim` and withdraws from the hook (`claim`).
///   - A pot without a ticket for ORPHAN_SECONDS (30 days) and no round to draw goes to the creator through
///     `settle`. If the registry disables the module, `rescue` pays the pot to the creator once no draw is
///     pending.
///   - Not identity-neutral (reads ctx.trader, pays a specific wallet, transfer hook that only records). Curve + pool.
contract JackpotModule is LedgerModuleBase {
    struct Config {
        uint16 bps; // of each trade's quote amount: 0.01% .. 5%
        uint32 roundSeconds; // 10 min .. 30 days
        uint96 minBuy; // quote units a buy must spend for tickets: $1 .. $500 at launch
        uint16 minHoldBps; // the winner must hold this share of the supply at the draw: 0.01% .. 1%
    }

    struct Entry {
        address buyer;
        uint96 cumEnd; // the round's ticket total after this entry
    }

    struct Received {
        uint64 blockNo;
        uint192 amount; // tokens received in `blockNo`
    }

    /// @dev Packed; registration warms the slots a gas-capped callback writes.
    struct Pool {
        // slot 0
        address token;
        uint16 bps;
        uint16 minHoldBps;
        uint32 roundSeconds;
        bool live;
        // slot 1
        address quote;
        uint96 minBuy;
        // slot 2
        address creator;
        uint64 lastTicketAt; // orphan clock (launch time until the first ticket)
        // slot 3
        uint128 pot; // this pool's share of the module's claim
        uint128 unverified; // credits announced to the hook, not yet checked against its books
        // slot 4: the open round
        uint32 round;
        uint40 start;
        uint32 entries; // log length
        uint128 tickets;
        // slot 5: the closed round waiting for its draw (closedRound 0 = none)
        uint32 closedRound;
        uint48 drawBlock;
        uint32 closedEntries;
        uint128 closedTickets;
        // slot 6
        uint128 totalPaid;
        uint32 rounds; // draws settled
    }

    uint16 public constant MAX_BPS = 500;
    uint32 public constant MIN_ROUND = 10 minutes;
    uint32 public constant MAX_ROUND = 30 days;
    uint16 public constant MIN_HOLD_BPS = 1;
    uint16 public constant MAX_HOLD_BPS = 100;
    /// @notice minBuy bounds in USD (18 decimals), checked at launch through the QuoteRegistry.
    uint256 public constant MIN_BUY_USD = 1e18;
    uint256 public constant MAX_BUY_USD = 500e18;
    uint32 public constant ORPHAN_SECONDS = 30 days;

    mapping(PoolId => Pool) internal _pools;
    mapping(address => PoolId) public poolOf;
    /// @dev pool => round => log index => entry
    mapping(PoolId => mapping(uint256 => mapping(uint256 => Entry))) internal _log;
    /// @dev pool => round => wallet => tickets
    mapping(PoolId => mapping(uint256 => mapping(address => uint256))) internal _tickets;
    mapping(PoolId => mapping(address => Received)) internal _received;

    event Registered(address indexed token, PoolId id, address quote, uint16 bps, uint32 roundSeconds);
    event Tickets(address indexed token, uint256 indexed round, address indexed buyer, uint256 tickets);
    event RoundClosed(address indexed token, uint256 indexed round, uint256 drawBlock, uint256 tickets, uint256 entries);
    event DrawRecommitted(address indexed token, uint256 indexed round, uint256 drawBlock);
    event JackpotWon(address indexed token, uint256 indexed round, address indexed winner, uint256 amount);
    event RolledOver(address indexed token, uint256 indexed round, address indexed winner, uint256 pot);
    event OrphanPotPaid(address indexed token, address indexed creator, uint256 amount);

    error UnknownToken();
    error TooEarly(uint256 drawBlock);
    error DrawPending();
    error MinBuyUsd(uint256 usd);

    constructor(address _hook) LedgerModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.bps == 0 || c.bps > MAX_BPS || c.minBuy == 0) revert BadConfig();
        if (c.roundSeconds < MIN_ROUND || c.roundSeconds > MAX_ROUND) revert BadConfig();
        if (c.minHoldBps < MIN_HOLD_BPS || c.minHoldBps > MAX_HOLD_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external override onlyHook {
        Pool storage p = _pools[id];
        if (p.live) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        uint256 usd = minBuyUsd(quote, c.minBuy);
        if (usd < MIN_BUY_USD || usd > MAX_BUY_USD) revert MinBuyUsd(usd);
        (p.token, p.bps, p.minHoldBps, p.roundSeconds, p.live) = (token, c.bps, c.minHoldBps, c.roundSeconds, true);
        (p.quote, p.minBuy) = (quote, c.minBuy);
        (p.creator, p.lastTicketAt) = (creator, uint64(block.timestamp));
        (p.round, p.start) = (1, uint40(block.timestamp));
        poolOf[token] = id;
        _seed(quote);
        emit Registered(token, id, quote, c.bps, c.roundSeconds);
    }

    /// @notice `minBuy` of `quote` in USD (18 decimals) at the QuoteRegistry's price (UI preview of the bound).
    function minBuyUsd(address quote, uint256 minBuy) public view returns (uint256) {
        IQuotePrices r = IQuotePrices(IAvaxHookV2View(hook).quoteRegistry());
        (, uint8 dec,) = r.quotes(quote);
        return Math.mulDiv(minBuy, r.usdPrice(quote), 10 ** dec);
    }

    // ---------------------------------------------------------------- trades

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        Credit[] memory c = _accrue(ctx.poolId, ctx.amountIn);
        Pool storage p = _pools[ctx.poolId];
        if (ctx.trader != address(0) && ctx.trader != p.creator && ctx.amountIn >= p.minBuy) {
            _addTickets(ctx.poolId, p, ctx.trader, ctx.amountIn);
        }
        return (0, c);
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _accrue(ctx.poolId, ctx.amountOut);
    }

    /// @dev Records what each wallet received in the current block (never refuses anything).
    function onTransfer(PoolId id, address, address, address, address to, uint256 amount) external override onlyHook {
        if (to == address(poolManager) || to == ModuleCaps.BURN) return;
        Received storage r = _received[id][to];
        if (r.blockNo != block.number) {
            (r.blockNo, r.amount) = (uint64(block.number), uint192(amount));
        } else {
            uint256 a = uint256(r.amount) + amount;
            r.amount = a > type(uint192).max ? type(uint192).max : uint192(a);
        }
    }

    function _accrue(PoolId id, uint256 amount) internal returns (Credit[] memory) {
        _reconcile();
        Pool storage p = _pools[id];
        _roll(p);
        uint256 share = (amount * p.bps) / BPS;
        if (share == 0) return new Credit[](0);
        p.pot += uint128(share);
        p.unverified += uint128(share);
        _expect(id, p.quote, share);
        return _one(address(this), share);
    }

    function _addTickets(PoolId id, Pool storage p, address buyer, uint256 amount) internal {
        uint256 total = p.tickets;
        uint256 room = type(uint96).max - total;
        if (amount > room) amount = room; // saturates instead of reverting a buy
        if (amount == 0) return;
        uint256 r = p.round;
        uint256 n = p.entries;
        total += amount;
        mapping(uint256 => Entry) storage log = _log[id][r];
        if (n > 0 && log[n - 1].buyer == buyer) {
            log[n - 1].cumEnd = uint96(total);
        } else {
            log[n] = Entry(buyer, uint96(total));
            p.entries = uint32(n + 1);
        }
        p.tickets = uint128(total);
        _tickets[id][r][buyer] += amount;
        p.lastTicketAt = uint64(block.timestamp);
        emit Tickets(p.token, r, buyer, amount);
    }

    /// @dev Closes the open round once it has ended (if no earlier draw is still waiting) and opens the next.
    function _roll(Pool storage p) internal {
        if (block.timestamp < uint256(p.start) + p.roundSeconds) return;
        if (p.tickets == 0) {
            // nobody to draw: just start over (the pot rolls on)
            p.start = uint40(block.timestamp);
            return;
        }
        if (p.closedRound != 0) return; // the previous draw first; this round keeps running until then
        (p.closedRound, p.drawBlock, p.closedEntries, p.closedTickets) = (p.round, uint48(block.number + 1), p.entries, p.tickets);
        emit RoundClosed(p.token, p.round, block.number + 1, p.tickets, p.entries);
        p.round += 1;
        p.start = uint40(block.timestamp);
        p.entries = 0;
        p.tickets = 0;
    }

    // ---------------------------------------------------------------- settle

    /// @notice Closes an ended round (commits its draw block), or draws a closed one and pays the winner the
    ///         pot as a claim in the hook (or rolls it over when the winner no longer holds `minHoldBps`). Also
    ///         pays an orphaned pot to the creator. Anyone (the keeper calls it after each round).
    /// @return winner the drawn wallet (0 if nothing was drawn)
    /// @return paid   what the winner received (0 = rolled over or not drawn yet)
    function settle(address token) external returns (address winner, uint256 paid) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        _reconcile();
        bool waiting = p.closedRound != 0;
        _roll(p);
        uint256 r = p.closedRound;
        if (r == 0) {
            _orphan(p);
            return (address(0), 0);
        }
        if (!waiting) return (address(0), 0); // just closed: the draw block was committed now
        uint256 db = p.drawBlock;
        if (block.number <= db) revert TooEarly(db);
        bytes32 bh = blockhash(db);
        if (bh == bytes32(0)) {
            // more than 256 blocks late: the hash is gone, commit to a fresh block
            p.drawBlock = uint48(block.number + 1);
            emit DrawRecommitted(token, r, block.number + 1);
            return (address(0), 0);
        }
        winner = _draw(id, r, p.closedEntries, uint256(keccak256(abi.encode(bh, id, r))) % p.closedTickets);
        p.closedRound = 0;
        p.rounds += 1;
        uint256 pot = p.pot;
        if (pot > 0 && _holding(id, token, winner) >= (TOTAL_SUPPLY * p.minHoldBps) / BPS) {
            p.pot = 0;
            p.totalPaid += uint128(pot);
            paid = pot;
            _payClaim(p.quote, winner, pot);
            emit JackpotWon(token, r, winner, pot);
        } else {
            emit RolledOver(token, r, winner, pot);
        }
        _roll(p); // the open round may have ended meanwhile
    }

    /// @dev Balance minus what arrived in this block.
    function _holding(PoolId id, address token, address who) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(who);
        Received storage r = _received[id][who];
        if (r.blockNo != block.number) return bal;
        return bal > r.amount ? bal - r.amount : 0;
    }

    /// @dev First log entry whose cumulative end exceeds `ticket` (binary search).
    function _draw(PoolId id, uint256 r, uint256 n, uint256 ticket) internal view returns (address) {
        mapping(uint256 => Entry) storage log = _log[id][r];
        uint256 lo;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (log[mid].cumEnd > ticket) hi = mid;
            else lo = mid + 1;
        }
        return log[lo].buyer;
    }

    function _orphan(Pool storage p) internal {
        uint256 pot = p.pot;
        if (pot == 0 || p.tickets != 0 || block.timestamp < uint256(p.lastTicketAt) + ORPHAN_SECONDS) return;
        p.pot = 0;
        p.totalPaid += uint128(pot);
        p.lastTicketAt = uint64(block.timestamp);
        _payClaim(p.quote, p.creator, pot);
        emit OrphanPotPaid(p.token, p.creator, pot);
    }

    // ---------------------------------------------------------------- views

    /// @return pot          the confirmed pot (the last trade's credit joins once the hook's books confirm it)
    /// @return round        the open round
    /// @return endsAt       when the open round ends (it keeps running while an earlier draw waits)
    /// @return tickets      tickets in the open round
    /// @return entries      log entries in the open round
    /// @return closedRound  the round waiting for its draw (0 = none)
    /// @return drawBlock    the block whose hash draws it (settle from drawBlock + 1, within 256 blocks)
    /// @return totalPaid    paid to winners (and orphaned pots) so far
    function jackpot(address token)
        external
        view
        returns (
            uint256 pot,
            uint256 round,
            uint256 endsAt,
            uint256 tickets,
            uint256 entries,
            uint256 closedRound,
            uint256 drawBlock,
            uint256 totalPaid
        )
    {
        Pool storage p = _pools[_poolIdOf(token)];
        return (
            p.pot - p.unverified,
            p.round,
            uint256(p.start) + p.roundSeconds,
            p.tickets,
            p.entries,
            p.closedRound,
            p.drawBlock,
            p.totalPaid
        );
    }

    /// @notice `wallet`'s tickets in `round` (the open round: `jackpot().round`).
    function ticketsOf(address token, uint256 round, address wallet) external view returns (uint256) {
        return _tickets[_poolIdOf(token)][round][wallet];
    }

    /// @notice True when calling `settle` now does something: draws (or re-commits) a closed round, closes an
    ///         ended round with tickets (commits its draw block), or pays an orphaned pot. Keeper hint.
    function canSettle(address token) external view returns (bool) {
        Pool storage p = _pools[_poolIdOf(token)];
        if (p.closedRound != 0) return block.number > p.drawBlock;
        if (p.tickets != 0) return block.timestamp >= uint256(p.start) + p.roundSeconds;
        return p.pot > p.unverified && block.timestamp >= uint256(p.lastTicketAt) + ORPHAN_SECONDS;
    }

    // ---------------------------------------------------------------- internals

    function _poolIdOf(address token) internal view returns (PoolId id) {
        id = poolOf[token];
        if (!_pools[id].live || _pools[id].token != token) revert UnknownToken();
    }

    /// @dev Rescue (module disabled) pays the creator only once no drawn round is waiting: settle it first.
    function _takeShare(PoolId id) internal override returns (address, uint256 amount) {
        Pool storage p = _pools[id];
        if (p.closedRound != 0) revert DrawPending();
        amount = p.pot;
        p.pot = 0;
        return (p.quote, amount);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Pool storage p = _pools[id];
        return (p.quote, p.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Pool storage p = _pools[id];
        p.pot = shortfall > p.pot ? 0 : p.pot - uint128(shortfall);
        p.unverified = 0;
    }
}
