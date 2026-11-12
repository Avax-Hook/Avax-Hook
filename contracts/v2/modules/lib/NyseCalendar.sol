// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title NyseCalendar
/// @notice US stock-market session times on-chain: Mon–Fri 9:30–16:00 America/New_York, with the US
///         daylight-saving rules (since 2007: from the 2nd Sunday of March 2:00 local to the 1st Sunday of
///         November 2:00 local) computed from the timestamp, and a hard-coded NYSE holiday and early-close
///         (13:00) table for 2026–2030. Outside 2026–2030 only weekends and hours apply.
///         Day numbers are days since 1970-01-01 (UTC calendar dates of the New York local day).
library NyseCalendar {
    uint256 internal constant OPEN = 9 hours + 30 minutes;
    uint256 internal constant CLOSE = 16 hours;
    uint256 internal constant EARLY_CLOSE = 13 hours;
    uint256 internal constant FIRST_YEAR = 2026;
    uint256 internal constant LAST_YEAR = 2030;
    /// @dev Longest run of closed days we search through (holiday + weekend runs are at most 4 days).
    uint256 internal constant SEARCH_DAYS = 10;

    // ---------------------------------------------------------------- tables
    // Each word packs up to 16 day numbers (uint16, lowest bits first; 0 = end of list).

    /// @dev NYSE full-day closures (observed dates).
    ///  2026: Jan 1, Jan 19, Feb 16, Apr 3 (Good Fri), May 25, Jun 19, Jul 3 (obs.), Sep 7, Nov 26, Dec 25
    ///  2027: Jan 1, Jan 18, Feb 15, Mar 26 (Good Fri), May 31, Jun 18 (obs.), Jul 5 (obs.), Sep 6, Nov 25,
    ///        Dec 24 (obs.)
    ///  2028: (Jan 1 is a Saturday: not observed) Jan 17, Feb 21, Apr 14 (Good Fri), May 29, Jun 19, Jul 4,
    ///        Sep 4, Nov 23, Dec 25
    ///  2029: Jan 1, Jan 15, Feb 19, Mar 30 (Good Fri), May 28, Jun 19, Jul 4, Sep 3, Nov 22, Dec 25
    ///  2030: Jan 1, Jan 21, Feb 18, Apr 19 (Good Fri), May 27, Jun 19, Jul 4, Sep 2, Nov 28, Dec 25
    function holidays(uint256 year) internal pure returns (uint256) {
        if (year == 2026) return 0x00514c512f50df509d508f5076504250144ff84fe6;
        if (year == 2027) return 0x0052b8529b524b520c51fb51e951a7518051645153;
        if (year == 2028) return 0x5427540753b75379536a5355532852f352d0;
        if (year == 2029) return 0x0055945573552354e654d754c15486545f543c542e;
        if (year == 2030) return 0x00570156e6568f56535644562d560755cb55af559b;
        return 0;
    }

    /// @dev NYSE 13:00 early closes: the day after Thanksgiving, Christmas Eve (Mon–Thu) and July 3 (when
    ///      July 4 falls Tue–Fri).
    ///  2026: Nov 27, Dec 24   2027: Nov 26   2028: Jul 3, Nov 24   2029: Jul 3, Nov 23, Dec 24
    ///  2030: Jul 3, Nov 29, Dec 24
    function earlyCloses(uint256 year) internal pure returns (uint256) {
        if (year == 2026) return 0x514b5130;
        if (year == 2027) return 0x529c;
        if (year == 2028) return 0x54085378;
        if (year == 2029) return 0x5593557454e5;
        if (year == 2030) return 0x570056e75652;
        return 0;
    }

    function _contains(uint256 packed, uint256 day) private pure returns (bool) {
        while (packed != 0) {
            if (packed & 0xffff == day) return true;
            packed >>= 16;
        }
        return false;
    }

    // ---------------------------------------------------------------- civil calendar (H. Hinnant)

    /// @dev Days since 1970-01-01 for a proleptic Gregorian date (year >= 1970).
    function daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    function civilFromDays(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }

    /// @dev 0 = Sunday ... 6 = Saturday (1970-01-01 was a Thursday).
    function weekday(uint256 day) internal pure returns (uint256) {
        return (day + 4) % 7;
    }

    /// @dev Day number of the n-th Sunday (n >= 1) of month m in year y.
    function nthSunday(uint256 y, uint256 m, uint256 n) internal pure returns (uint256) {
        uint256 first = daysFromCivil(y, m, 1);
        return first + (7 - weekday(first)) % 7 + 7 * (n - 1);
    }

    // ---------------------------------------------------------------- New York time

    /// @notice New York's offset behind UTC at `ts`: 4h during daylight saving, else 5h.
    function utcOffset(uint256 ts) internal pure returns (uint256) {
        (uint256 y,,) = civilFromDays(ts / 1 days);
        uint256 start = nthSunday(y, 3, 2) * 1 days + 7 hours; // 02:00 EST = 07:00 UTC
        uint256 end = nthSunday(y, 11, 1) * 1 days + 6 hours; // 02:00 EDT = 06:00 UTC
        return ts >= start && ts < end ? 4 hours : 5 hours;
    }

    /// @notice Session of the New York day `day`, in seconds after local midnight; (0, 0) when closed.
    function session(uint256 day, bool observeHolidays, bool observeEarlyCloses)
        internal
        pure
        returns (uint256 open, uint256 close)
    {
        uint256 w = weekday(day);
        if (w == 0 || w == 6) return (0, 0);
        close = CLOSE;
        if (observeHolidays || observeEarlyCloses) {
            (uint256 y,,) = civilFromDays(day);
            if (y >= FIRST_YEAR && y <= LAST_YEAR) {
                if (observeHolidays && _contains(holidays(y), day)) return (0, 0);
                if (observeEarlyCloses && _contains(earlyCloses(y), day)) close = EARLY_CLOSE;
            }
        }
        open = OPEN;
    }

    /// @notice Whether the market is open at `ts`.
    function isOpen(uint256 ts, bool observeHolidays, bool observeEarlyCloses) internal pure returns (bool) {
        uint256 local = ts - utcOffset(ts);
        uint256 secs = local % 1 days;
        if (secs < OPEN || secs >= CLOSE) return false; // cheap reject before any table lookup
        (uint256 o, uint256 c) = session(local / 1 days, observeHolidays, observeEarlyCloses);
        return c != 0 && secs >= o && secs < c;
    }

    /// @notice If open at `ts`: (true, ts, close time). Else (false, next open time, its close time).
    ///         Returns zeros if nothing opens within SEARCH_DAYS (cannot happen with the built-in table).
    function status(uint256 ts, bool observeHolidays, bool observeEarlyCloses)
        internal
        pure
        returns (bool open, uint256 opensAt, uint256 closesAt)
    {
        uint256 day = (ts - utcOffset(ts)) / 1 days;
        for (uint256 i; i <= SEARCH_DAYS; ++i) {
            (uint256 o, uint256 c) = session(day + i, observeHolidays, observeEarlyCloses);
            if (c == 0) continue;
            // Sessions are on weekdays, far from the Sunday 02:00 switch: noon UTC has the day's offset.
            uint256 off = utcOffset((day + i) * 1 days + 12 hours);
            uint256 oAt = (day + i) * 1 days + o + off;
            uint256 cAt = (day + i) * 1 days + c + off;
            if (ts < cAt) return (ts >= oAt, ts >= oAt ? ts : oAt, cAt);
        }
    }
}
