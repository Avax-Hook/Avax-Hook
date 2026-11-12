// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {PoolModules} from "./lib/PoolModules.sol";
import {HookModuleBase, IAvaxHookV2View} from "./HookModuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {TxTally} from "./lib/ModuleMath.sol";

/// @title ChaptersModule
/// @notice A max-per-wallet cap that doubles every time the token's cumulative trade volume crosses another
///         chapter. cap = startBps · 2^chapter, chapter = volume / chapterTokens; once the cap would reach
///         `maxBps` there is no cap any more (for good: volume only grows).
///   - Volume = tokens moved by every trade, curve and pool, router or not: tokens received on buys
///     (`amountOut`) plus tokens sold (`amountIn`), counted in onAfterSwap. Wash trading moves it too; that
///     costs the trader the fees on every round trip.
///   - The cap a transfer is checked against uses the volume from BEFORE the current transaction, so a big buy
///     can't open the chapter it needs by itself (its own volume is kept in transient storage and left out).
///   - Like MaxPerWalletModule: no wallet may end up holding more than the cap, whether it buys or receives a
///     transfer. Selling and sending are never limited. The PoolManager, the launchpad, the hook, 0x…dEaD,
///     this module and the pool's other modules (Auto-LP vault, pots) are exempt; the creator is not. Contracts holding tokens mid-route (some aggregators)
///     count as wallets. Splitting a bag across wallets gets around any holding cap.
///   Gas: one storage write per swap, one balance read per transfer.
///   - Claims bypass guard (2026-11-12): While there is a cap, pool buys that don't come through the
///     AvaxHook router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly():
///     such a swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the
///     ERC-20, so this rule would never see them. Trade through the AvaxHook router (site, Zap, limit orders)
///     or the curve.
contract ChaptersModule is HookModuleBase, TxTally {
    struct Config {
        uint16 startBps; // first chapter's cap, of the 1B supply: 0.1% .. 50%
        uint16 maxBps; // when the cap would reach this, the cap is lifted: > start .. 100%
        uint128 chapterTokens; // volume per chapter (18 decimals): 1M .. 10B tokens
    }

    struct Book {
        Config cfg; // 20 bytes
        address token;
        uint256 volume; // cumulative tokens traded
        bool registered;
    }

    uint16 public constant MIN_START_BPS = 10;
    uint16 public constant MAX_START_BPS = 5_000;
    uint128 public constant MIN_CHAPTER = 1_000_000 ether;
    uint128 public constant MAX_CHAPTER = 10_000_000_000 ether;
    bytes32 internal constant TX_VOL = keccak256("avaxhook.v2.chapters.txvol");

    mapping(PoolId => Book) internal _books;
    mapping(address => PoolId) public poolOf;

    event ChapterOpened(address indexed token, uint256 chapter, uint256 cap);

    error MaxWalletExceeded(address wallet, uint256 balance, uint256 cap);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.ON_TRANSFER;
    }

    /// @dev Claims bypass guard: while there is a cap, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy) {
            Book storage b = _books[ctx.poolId];
            Config memory c = b.cfg;
            if (_capBps(c, (b.volume - _tload(_txKey(ctx.poolId))) / c.chapterTokens) != 0) RouterOnlyGuard.check(ctx);
        }
        return (0, new Credit[](0));
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_HOLDING_CAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.startBps < MIN_START_BPS || c.startBps > MAX_START_BPS) revert BadConfig();
        if (c.maxBps <= c.startBps || c.maxBps > BPS) revert BadConfig();
        if (c.chapterTokens < MIN_CHAPTER || c.chapterTokens > MAX_CHAPTER) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Book storage b = _books[id];
        if (b.registered) revert AlreadyRegistered();
        b.cfg = abi.decode(config, (Config));
        b.token = token;
        b.registered = true;
        poolOf[token] = id;
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        Book storage b = _books[ctx.poolId];
        uint256 moved = ctx.isBuy ? ctx.amountOut : ctx.amountIn;
        if (moved == 0) return new Credit[](0);
        Config memory c = b.cfg;
        uint256 before = b.volume;
        uint256 v = before + moved;
        b.volume = v;
        _tallyAdd(_txKey(ctx.poolId), moved);
        uint256 ch0 = before / c.chapterTokens;
        uint256 ch1 = v / c.chapterTokens;
        if (ch1 > ch0 && _capBps(c, ch0) != 0) emit ChapterOpened(b.token, ch1, (TOTAL_SUPPLY * _capBps(c, ch1)) / BPS);
        return new Credit[](0);
    }

    function onTransfer(PoolId id, address token, address, address, address to, uint256) external view override onlyHook {
        if (to == address(poolManager) || to == ModuleCaps.BURN || to == hook || to == address(this)) return;
        if (to == IAvaxHookV2View(hook).launchpad()) return;
        Book storage b = _books[id];
        Config memory c = b.cfg;
        uint256 v = b.volume - _tload(_txKey(id)); // volume before this transaction
        uint256 bps = _capBps(c, v / c.chapterTokens);
        if (bps == 0) return;
        uint256 cap = (TOTAL_SUPPLY * bps) / BPS;
        uint256 bal = IERC20(token).balanceOf(to);
        if (bal > cap && !PoolModules.isModule(hook, id, to)) revert MaxWalletExceeded(to, bal, cap);
    }

    // ---------------------------------------------------------------- views

    /// @return cap         the max per wallet now (0 = no cap any more)
    /// @return chapter     chapters completed so far
    /// @return volume      cumulative tokens traded
    /// @return nextChapter volume at which the cap doubles next (0 = no cap any more)
    function currentCap(address token)
        external
        view
        returns (uint256 cap, uint256 chapter, uint256 volume, uint256 nextChapter)
    {
        Book storage b = _books[poolOf[token]];
        Config memory c = b.cfg;
        if (c.chapterTokens == 0) return (0, 0, 0, 0);
        volume = b.volume;
        chapter = volume / c.chapterTokens;
        uint256 bps = _capBps(c, chapter);
        if (bps == 0) return (0, chapter, volume, 0);
        return ((TOTAL_SUPPLY * bps) / BPS, chapter, volume, (chapter + 1) * c.chapterTokens);
    }

    function configOf(address token) external view returns (Config memory) {
        return _books[poolOf[token]].cfg;
    }

    // ---------------------------------------------------------------- internals

    /// @dev Cap in bps for `chapter`, 0 when it has reached `maxBps` (no cap).
    function _capBps(Config memory c, uint256 chapter) internal pure returns (uint256) {
        if (chapter >= 16) return 0; // start >= 10 bps: 2^10 already passes 100%
        uint256 bps = uint256(c.startBps) << chapter;
        return bps >= c.maxBps ? 0 : bps;
    }

    function _txKey(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(TX_VOL, id));
    }
}
