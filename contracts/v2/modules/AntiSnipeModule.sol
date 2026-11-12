// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {WindowedModuleBase} from "./WindowedModuleBase.sol";

/// @notice A module that can take the snipe tax into a pot (NthBuyPotModule, LastBuyerPotModule).
interface ISnipeTaxSink {
    /// @return priority lower wins when a pool has several sinks (v1: Nth-buy pot first, then last-buyer pot)
    function snipeTaxSinkPriority() external view returns (uint8 priority);

    /// @notice Books `amount` (credited to the sink by the caller's current swap callback) into pool `id`'s pot.
    function addSnipeTax(PoolId id, uint256 amount) external;
}

/// @title AntiSnipeModule
/// @notice v1 "Anti-snipe", pool phase (the curve phase keeps the launchpad's own CurveGuard). For the first
///         `guardBlocks` blocks after the pool opens:
///   - buys share a cumulative per-block cap of `maxBuyPerBlock` quote units (0 = no cap). A sell gives cap
///     back only for buys made earlier in the SAME transaction (up to the quote it took out), so a buy and a
///     sell in one transaction can't fill the cap and lock honest buyers out for the price of the fees, while
///     other people's sells in the block never make room for a sniper;
///   - every buy pays `snipeTaxBps` of its input as snipe tax. Like v1 it funds a pot for the buyers after
///     the snipers: the pool's Nth-buy pot if it has one, else its last-buyer pot, else the protocol;
///   - nobody but the launchpad may add liquidity.
///   Exact-output buys are refused by the core for every pool.
///   Sells are never refused or taxed (it doesn't declare BLOCKS_SELLS); during the guard they only give back
///   the cap of their own transaction's earlier buys (after the swap, when the quote out is known). Pool phase only: on the bonding
///   curve it does nothing (the launchpad's CurveGuard is the curve's anti-snipe).
contract AntiSnipeModule is WindowedModuleBase {
    struct Config {
        uint32 guardBlocks; // 1 .. 7,200 blocks
        uint96 maxBuyPerBlock; // quote units, 0 = no cap
        uint16 snipeTaxBps; // 0 .. 2,500
    }

    /// @dev Flat and packed (2 slots): a guarded first buy must fit the hook's 200k module gas.
    struct Guard {
        uint32 guardBlocks;
        uint96 maxBuyPerBlock;
        uint16 snipeTaxBps;
        uint64 block_; // block of `spent`
        bool registered;
        uint96 spent; // net buys so far in `block_` (quote in of buys, less quote out of sells)
        address sink; // pot module that takes the snipe tax (UNRESOLVED until the first buy, NO_SINK = protocol)
    }

    uint32 public constant MAX_GUARD_BLOCKS = 7_200;
    uint16 public constant MAX_SNIPE_TAX_BPS = 2_500;
    /// @notice AvaxHookV2.PROTOCOL: the claim account the protocol fee accrues to.
    /// @dev Transient, per pool: quote of the buys counted in this transaction that no sell has netted yet.
    bytes32 internal constant TX_BOUGHT = keccak256("avaxhook.v2.antisnipe.txBought");

    address public constant PROTOCOL = address(uint160(uint256(keccak256("avaxhook.v2.protocol"))));
    address internal constant NO_SINK = address(1);
    address internal constant UNRESOLVED = address(2);

    mapping(PoolId => Guard) internal _guards;

    event SnipeTax(PoolId indexed id, address indexed to, uint256 amount);

    error MaxBuyExceeded(uint256 attempted, uint256 cap);
    error LiquidityLockedDuringGuard();

    constructor(address _hook) WindowedModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP | ModuleCaps.LIQUIDITY;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.guardBlocks == 0 || c.guardBlocks > MAX_GUARD_BLOCKS || c.snipeTaxBps > MAX_SNIPE_TAX_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address, address, address, bytes calldata config) external override onlyHook {
        Guard storage g = _guards[id];
        if (g.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (g.guardBlocks, g.maxBuyPerBlock, g.snipeTaxBps) = (c.guardBlocks, c.maxBuyPerBlock, c.snipeTaxBps);
        g.registered = true;
        g.sink = UNRESOLVED; // both slots non-zero: the first guarded buy writes no fresh storage
        _seedWindows(id);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        // The curve phase has its own guard in the launchpad (CurveGuard): don't cap or tax twice.
        if (!ctx.isBuy || ctx.phase == ModuleCaps.PHASE_CURVE) return (0, new Credit[](0));
        Guard storage g = _guards[ctx.poolId];
        address sink = g.sink;
        if (sink == UNRESOLVED) sink = _resolve(ctx.poolId, g);
        if (!_within(ctx.poolId, g.guardBlocks)) return (0, new Credit[](0));

        uint256 cap = g.maxBuyPerBlock;
        if (cap != 0) {
            uint256 total = (g.block_ == block.number ? g.spent : 0) + ctx.amountIn;
            if (total > cap) revert MaxBuyExceeded(total, cap);
            g.block_ = uint64(block.number);
            g.spent = uint96(total);
            bytes32 k = _txKey(ctx.poolId);
            uint256 b;
            assembly ("memory-safe") {
                b := tload(k)
            }
            b += ctx.amountIn;
            assembly ("memory-safe") {
                tstore(k, b)
            }
        }

        uint256 tax = (ctx.amountIn * g.snipeTaxBps) / BPS;
        if (tax == 0) return (0, new Credit[](0));
        address to = sink;
        if (to == NO_SINK || AvaxHookV2(payable(hook)).disabled(to)) {
            to = PROTOCOL;
        } else {
            // The hook books the credit below once every module has run (maybe scaled down to fit the cut
            // cap); the pot counts it as unverified and checks it against the hook's books later.
            ISnipeTaxSink(to).addSnipeTax(ctx.poolId, tax);
        }
        emit SnipeTax(ctx.poolId, to, tax);
        return (0, _one(to, tax));
    }

    /// @dev A sell in the guard gives back the cap of this transaction's earlier buys, up to the quote it took out.
    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy || ctx.phase == ModuleCaps.PHASE_CURVE) return new Credit[](0);
        Guard storage g = _guards[ctx.poolId];
        if (g.maxBuyPerBlock == 0 || g.block_ != block.number) return new Credit[](0);
        bytes32 k = _txKey(ctx.poolId);
        uint256 b;
        assembly ("memory-safe") {
            b := tload(k)
        }
        if (b == 0) return new Credit[](0);
        uint256 free = ctx.amountOut < b ? ctx.amountOut : b;
        uint256 spent = g.spent;
        if (free > spent) free = spent;
        g.spent = uint96(spent - free);
        b -= free;
        assembly ("memory-safe") {
            tstore(k, b)
        }
        return new Credit[](0);
    }

    function _txKey(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(TX_BOUGHT, id));
    }

    function onLiquidity(PoolId id, address, bool isAdd, ModifyLiquidityParams calldata) external override onlyHook {
        if (isAdd && _within(id, _guards[id].guardBlocks)) revert LiquidityLockedDuringGuard();
    }

    // ---------------------------------------------------------------- views

    function guardActive(PoolId id) external view returns (bool) {
        return _withinView(id, _guards[id].guardBlocks);
    }

    function guardOf(PoolId id) external view returns (Guard memory) {
        return _guards[id];
    }

    // ---------------------------------------------------------------- internals

    /// @dev First buy: one poolInfo read caches the open block and finds the pool's snipe-tax pot among its
    ///      modules (lowest priority wins).
    function _resolve(PoolId id, Guard storage g) internal returns (address sink) {
        AvaxHookV2.PoolView memory info = AvaxHookV2(payable(hook)).poolInfo(id);
        if (info.openBlock != 0) _openBlockCache[id] = info.openBlock;
        uint256 best = type(uint256).max;
        for (uint256 i; i < info.modules.length; ++i) {
            address m = info.modules[i];
            if (m == address(this)) continue;
            (bool ok, bytes memory ret) = m.staticcall{gas: 10_000}(abi.encodeCall(ISnipeTaxSink.snipeTaxSinkPriority, ()));
            if (!ok || ret.length != 32) continue;
            uint256 p = abi.decode(ret, (uint256));
            if (p < best) (best, sink) = (p, m);
        }
        if (sink == address(0)) sink = NO_SINK;
        g.sink = sink;
    }
}
