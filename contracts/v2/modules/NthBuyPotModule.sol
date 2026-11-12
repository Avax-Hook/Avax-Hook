// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";
import {ISnipeTaxSink} from "./AntiSnipeModule.sol";

/// @title NthBuyPotModule
/// @notice v1 "Nth-buy pot": `potBps` of every pool buy's quote input fills a pot (plus the pool's snipe tax,
///         see AntiSnipeModule). Each qualifying buy moves a public counter by one, at most once per block,
///         and the buy that lands on a multiple of `everyNBuys` takes the whole pot, its own share included.
///         Deterministic, no randomness claimed.
///   Qualifying (HK-3): a router buy (trusted buyer identity, never a spoofable hookData from someone else) of at
///   least `minBuy` quote units. The core makes every buy fill completely, so a buy qualifies on what it
///   really bought. The pot is this module's claim in the hook; the winner is paid with `transferClaim`
///   and claims from the hook.
///   Both phases: bonding-curve buys (the launchpad names the buyer) fill and count exactly like pool buys.
///   A pot with no qualifying buy for `ORPHAN_SECONDS` (30 days, counted from launch until the first one)
///   goes to the creator through the permissionless `settle`, so it can't sit stuck (as LastBuyerPot).
contract NthBuyPotModule is LedgerModuleBase, ISnipeTaxSink {
    struct Config {
        uint16 potBps; // 1 .. 1,000 (10%)
        uint32 everyNBuys; // 2 .. 100,000
        uint96 minBuy; // quote units, > 0
    }

    /// @dev Flat and packed (3 slots): a guarded first buy must fit the hook's 200k module gas.
    struct Pot {
        uint16 potBps;
        uint32 everyNBuys;
        uint96 minBuy;
        uint48 lastBlock; // block of the last counted buy
        uint64 buyCount;
        address quote;
        uint96 totalPaid;
        uint128 pot; // this pool's share of the module's claim
        uint88 unverified; // credits announced to the hook, not yet checked against its books
        uint32 lastBuyAt; // last qualifying buy (launch time until the first one)
        bool live; // set at registration so the pot's slot is never fresh inside a gas-capped callback
    }

    uint16 public constant MAX_POT_BPS = 1_000;
    uint32 public constant MAX_EVERY_N = 100_000;
    /// @notice A pot with no qualifying buy for this long goes to the creator (`settle`).
    uint32 public constant ORPHAN_SECONDS = 30 days;

    mapping(PoolId => Pot) internal _pots;

    event JackpotHit(PoolId indexed id, address indexed winner, uint256 amount, uint256 buyNumber);
    event OrphanPotPaid(PoolId indexed id, address indexed creator, uint256 amount);

    error NotPoolModule();

    constructor(address _hook) LedgerModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    function validateConfig(bytes calldata config) public pure virtual override {
        Config memory c = abi.decode(config, (Config));
        if (c.potBps == 0 || c.potBps > MAX_POT_BPS || c.minBuy == 0) revert BadConfig();
        if (c.everyNBuys < 2 || c.everyNBuys > MAX_EVERY_N) revert BadConfig();
    }

    function onRegister(PoolId id, address, address quote, address, bytes calldata config) external override onlyHook {
        Pot storage p = _pots[id];
        if (p.everyNBuys != 0) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (p.potBps, p.everyNBuys, p.minBuy) = (c.potBps, c.everyNBuys, c.minBuy);
        p.quote = quote;
        p.live = true;
        p.lastBuyAt = uint32(block.timestamp);
        _seed(quote);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        uint256 fresh = _reconcile();
        Pot storage p = _pots[ctx.poolId];
        uint256 share = (ctx.amountIn * p.potBps) / BPS;

        if (ctx.trader != address(0) && ctx.amountIn >= p.minBuy && p.lastBlock != block.number) {
            p.lastBlock = uint48(block.number);
            p.lastBuyAt = uint32(block.timestamp);
            uint64 count = p.buyCount + 1;
            p.buyCount = count;
            // Snipe tax announced earlier in this same callback isn't booked yet: it stays for the next round.
            uint256 held = p.pot - fresh;
            if (count % p.everyNBuys == 0 && held + share > 0) {
                // The winner takes the pot and this buy's own share (credited straight to them).
                p.pot = uint128(fresh);
                p.totalPaid += uint96(held + share);
                if (held > 0) _payClaim(p.quote, ctx.trader, held);
                emit JackpotHit(ctx.poolId, ctx.trader, held + share, count);
                return (0, share == 0 ? new Credit[](0) : _one(ctx.trader, share));
            }
        }
        if (share == 0) return (0, new Credit[](0));
        p.pot += uint128(share);
        p.unverified += uint88(share);
        _expect(ctx.poolId, p.quote, share);
        return (0, _one(address(this), share));
    }

    /// @notice Pays a pot that had no qualifying buy for ORPHAN_SECONDS to the pool's creator. Anyone.
    function settle(PoolId id) external virtual {
        _reconcile();
        Pot storage p = _pots[id];
        uint256 held = p.pot;
        if (held == 0 || block.timestamp < uint256(p.lastBuyAt) + ORPHAN_SECONDS) return;
        address creator = AvaxHookV2(payable(hook)).poolInfo(id).creator;
        p.pot = 0;
        p.totalPaid += uint96(held);
        _payClaim(p.quote, creator, held);
        emit OrphanPotPaid(id, creator, held);
    }

    // ---------------------------------------------------------------- snipe tax sink

    function snipeTaxSinkPriority() external pure returns (uint8) {
        return 1; // v1: the snipe tax funds the Nth-buy pot first
    }

    /// @notice Called by another module of pool `id` (AntiSnipeModule) during a swap callback in which it
    ///         credits `amount` to this module. Checked against the real balance on the next reconcile.
    function addSnipeTax(PoolId id, uint256 amount) external {
        Pot storage p = _pots[id];
        if (p.everyNBuys == 0 || !_isPoolModule(id, msg.sender)) revert NotPoolModule();
        _reconcile();
        p.pot += uint128(amount);
        p.unverified += uint88(amount);
        _expect(id, p.quote, amount);
    }

    // ---------------------------------------------------------------- views

    function potOf(PoolId id) external view returns (Pot memory) {
        return _pots[id];
    }

    /// @notice Qualifying buys until the next payout (1 = the next qualifying buy wins).
    function buysUntilPot(PoolId id) external view returns (uint256) {
        Pot storage p = _pots[id];
        if (p.everyNBuys == 0) return 0;
        return p.everyNBuys - (p.buyCount % p.everyNBuys);
    }

    // ---------------------------------------------------------------- internals

    function _takeShare(PoolId id) internal override returns (address, uint256 amount) {
        Pot storage p = _pots[id];
        amount = p.pot;
        p.pot = 0;
        return (p.quote, amount);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Pot storage p = _pots[id];
        return (p.quote, p.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Pot storage p = _pots[id];
        p.pot = shortfall > p.pot ? 0 : p.pot - uint128(shortfall);
        p.unverified = 0;
    }
}
