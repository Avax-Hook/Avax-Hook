// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";
import {NyseCalendar} from "./lib/NyseCalendar.sol";

/// @title MarketHoursBase
/// @notice The pool trades only while the US stock market is open: Monday–Friday 9:30–16:00 New York time,
///         daylight saving computed on-chain. Optionally closed on NYSE holidays and closing at 13:00 on NYSE
///         early-close days (table for 2026–2030; later years fall back to weekends and hours only).
///   - Applies to every trade: bonding-curve buys and sells, and every v4 pool swap (router, aggregators,
///     bots). Wallet-to-wallet transfers are never restricted. A launch with a dev buy outside the session
///     reverts (the dev buy is a curve trade).
///   - Two deployments of the same rule: MarketHoursModule closes buys AND sells after hours (it declares
///     BLOCKS_SELLS); MarketHoursSellsOpenModule closes buys only, sells stay open around the clock (it does
///     not declare BLOCKS_SELLS, so the hook isolates it on sells like any other module).
///   - Unscheduled closures (national days of mourning, emergencies) are not known on-chain.
abstract contract MarketHoursBase is HookModuleBase {
    struct Config {
        bool observeHolidays; // closed on NYSE holidays (2026–2030 table)
        bool observeEarlyCloses; // close at 13:00 on NYSE early-close days (2026–2030 table)
    }

    struct Rule {
        Config cfg;
        bool registered;
    }

    mapping(PoolId => Rule) internal _rules;
    mapping(address => PoolId) public poolOf;

    /// @param opensAt next opening time (unix seconds)
    error MarketClosed(uint256 opensAt);

    constructor(address _hook) HookModuleBase(_hook) {}

    /// @dev true: sells are never refused (and the module is isolated on sells).
    function sellsAlwaysOpen() public pure virtual returns (bool);

    function capabilities() external pure override returns (uint16) {
        return sellsAlwaysOpen() ? ModuleCaps.BEFORE_SWAP : ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_SCHEDULE;
    }

    function validateConfig(bytes calldata config) public pure override {
        abi.decode(config, (Config)); // every combination of the two flags is valid
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        r.cfg = abi.decode(config, (Config));
        r.registered = true;
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy || !sellsAlwaysOpen()) {
            Config memory c = _rules[ctx.poolId].cfg;
            if (!NyseCalendar.isOpen(block.timestamp, c.observeHolidays, c.observeEarlyCloses)) {
                (, uint256 opensAt,) = NyseCalendar.status(block.timestamp, c.observeHolidays, c.observeEarlyCloses);
                revert MarketClosed(opensAt);
            }
        }
        return (0, new Credit[](0));
    }

    // ---------------------------------------------------------------- views

    /// @notice Market state for a token's pool now.
    /// @return open     whether trades (buys; also sells unless sells stay open) are accepted now
    /// @return opensAt  now if open, else the next opening time
    /// @return closesAt the end of the current (or next) session
    function marketStatus(address token) external view returns (bool open, uint256 opensAt, uint256 closesAt) {
        Config memory c = _rules[poolOf[token]].cfg;
        return NyseCalendar.status(block.timestamp, c.observeHolidays, c.observeEarlyCloses);
    }

    /// @notice The calendar for any time and options (UI clocks, tests).
    function statusAt(uint256 ts, bool observeHolidays, bool observeEarlyCloses)
        external
        pure
        returns (bool open, uint256 opensAt, uint256 closesAt)
    {
        return NyseCalendar.status(ts, observeHolidays, observeEarlyCloses);
    }

    /// @notice New York's offset behind UTC at `ts` (14400 during daylight saving, else 18000).
    function newYorkOffset(uint256 ts) external pure returns (uint256) {
        return NyseCalendar.utcOffset(ts);
    }

    function configOf(PoolId id) external view returns (Config memory) {
        return _rules[id].cfg;
    }
}

/// @title MarketHoursModule
/// @notice Market hours with everything closed after hours: buys AND sells are refused outside the session.
contract MarketHoursModule is MarketHoursBase {
    constructor(address _hook) MarketHoursBase(_hook) {}

    function sellsAlwaysOpen() public pure override returns (bool) {
        return false;
    }
}
