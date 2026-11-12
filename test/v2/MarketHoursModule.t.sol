// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {MarketHoursBase, MarketHoursModule} from "../../contracts/v2/modules/MarketHoursModule.sol";
import {MarketHoursSellsOpenModule} from "../../contracts/v2/modules/MarketHoursSellsOpenModule.sol";
import {NyseCalendar} from "../../contracts/v2/modules/lib/NyseCalendar.sol";
import {NewModulesBase} from "./NewModulesBase.t.sol";

contract CalendarHarness {
    function isOpen(uint256 ts, bool h, bool e) external pure returns (bool) {
        return NyseCalendar.isOpen(ts, h, e);
    }

    function status(uint256 ts, bool h, bool e) external pure returns (bool, uint256, uint256) {
        return NyseCalendar.status(ts, h, e);
    }

    function offset(uint256 ts) external pure returns (uint256) {
        return NyseCalendar.utcOffset(ts);
    }

    function holidays(uint256 y) external pure returns (uint256) {
        return NyseCalendar.holidays(y);
    }

    function earlyCloses(uint256 y) external pure returns (uint256) {
        return NyseCalendar.earlyCloses(y);
    }

    function civil(uint256 day) external pure returns (uint256, uint256, uint256) {
        return NyseCalendar.civilFromDays(day);
    }

    function daysOf(uint256 y, uint256 m, uint256 d) external pure returns (uint256) {
        return NyseCalendar.daysFromCivil(y, m, d);
    }
}

/// Calendar math against the IANA tz database (timestamps generated offline with Intl/America/New_York).
contract NyseCalendarTest is Test {
    CalendarHarness c = new CalendarHarness();

    // New York wall times -> UTC (tz database)
    uint256 constant MON_OCT5_0930 = 1791207000; // EDT
    uint256 constant MON_OCT5_1600 = 1791230400;
    uint256 constant FRI_OCT30_0930 = 1793367000; // last week of EDT
    uint256 constant MON_NOV2_0930 = 1793629800; // first day of EST
    uint256 constant MON_NOV2_1600 = 1793653200;
    uint256 constant FRI_MAR12_2027_0930 = 1804861800; // EST
    uint256 constant MON_MAR15_2027_0930 = 1805117400; // first day of EDT
    uint256 constant THANKSGIVING_2026_NOON = 1795712400;
    uint256 constant NOV27_2026_1300 = 1795802400; // early close
    uint256 constant DEC24_2026_1300 = 1798135200; // early close
    uint256 constant XMAS_2026_NOON = 1798218000;
    uint256 constant MON_DEC28_2026_0930 = 1798468200;
    uint256 constant GOOD_FRIDAY_2027_NOON = 1806076800;
    uint256 constant JUNETEENTH_OBS_2027_NOON = 1813334400; // Fri Jun 18 2027 (19th is a Saturday)
    uint256 constant JAN1_2031_NOON = 1925053200; // beyond the table
    uint256 constant MON_JAN3_2028_NOON = 1830531600; // Jan 1 2028 is a Saturday: not observed
    uint256 constant FRI_OCT9_1600 = 1791576000;
    uint256 constant MON_OCT12_0930 = 1791811800; // Columbus Day: NYSE open
    uint256 constant WED_OCT7_NOON = 1791388800;

    function test_sessionEdgesEdt() public view {
        assertFalse(c.isOpen(MON_OCT5_0930 - 1, true, true));
        assertTrue(c.isOpen(MON_OCT5_0930, true, true));
        assertTrue(c.isOpen(MON_OCT5_1600 - 1, true, true));
        assertFalse(c.isOpen(MON_OCT5_1600, true, true));
        assertTrue(c.isOpen(WED_OCT7_NOON, false, false));
        assertTrue(c.isOpen(MON_OCT12_0930, true, true));
    }

    function test_dstEndsFirstSundayOfNovember() public view {
        assertEq(c.offset(FRI_OCT30_0930), 4 hours);
        assertTrue(c.isOpen(FRI_OCT30_0930, true, true));
        assertEq(c.offset(MON_NOV2_0930), 5 hours);
        // 9:30 EST is 14:30 UTC: at 13:30 UTC (what 9:30 was a week earlier) it is still 8:30
        assertFalse(c.isOpen(MON_NOV2_0930 - 1 hours, true, true));
        assertTrue(c.isOpen(MON_NOV2_0930, true, true));
        assertTrue(c.isOpen(MON_NOV2_1600 - 1, true, true));
        assertFalse(c.isOpen(MON_NOV2_1600, true, true));
    }

    function test_dstStartsSecondSundayOfMarch() public view {
        assertEq(c.offset(FRI_MAR12_2027_0930), 5 hours);
        assertFalse(c.isOpen(FRI_MAR12_2027_0930 - 1, true, true));
        assertTrue(c.isOpen(FRI_MAR12_2027_0930, true, true));
        assertEq(c.offset(MON_MAR15_2027_0930), 4 hours);
        assertFalse(c.isOpen(MON_MAR15_2027_0930 - 1, true, true));
        assertTrue(c.isOpen(MON_MAR15_2027_0930, true, true));
        assertTrue(c.isOpen(MON_MAR15_2027_0930 + 1 hours, true, true));
    }

    /// Every US DST switch 2026-2045 from the tz database: the offset flips exactly at that second.
    function test_dstTransitionsMatchTzDatabase() public view {
        uint256[40] memory t = [
            uint256(1772953200), 1793512800, 1805007600, 1825567200, 1836457200, 1857016800, 1867906800, 1888466400,
            1899356400, 1919916000, 1930806000, 1951365600, 1962860400, 1983420000, 1994310000, 2014869600,
            2025759600, 2046319200, 2057209200, 2077768800, 2088658800, 2109218400, 2120108400, 2140668000,
            2152162800, 2172722400, 2183612400, 2204172000, 2215062000, 2235621600, 2246511600, 2267071200,
            2277961200, 2298520800, 2309410800, 2329970400, 2341465200, 2362024800, 2372914800, 2393474400
        ];
        for (uint256 i; i < 40; ++i) {
            bool start = i % 2 == 0; // March: EST -> EDT
            assertEq(c.offset(t[i] - 1), start ? 5 hours : 4 hours, "before switch");
            assertEq(c.offset(t[i]), start ? 4 hours : 5 hours, "at switch");
        }
    }

    function test_weekendClosed() public view {
        // Sat Oct 10 2026, noon NY
        assertFalse(c.isOpen(WED_OCT7_NOON + 3 days, false, false));
        assertFalse(c.isOpen(WED_OCT7_NOON + 4 days, false, false));
        (bool open, uint256 opensAt, uint256 closesAt) = c.status(FRI_OCT9_1600, true, true);
        assertFalse(open);
        assertEq(opensAt, MON_OCT12_0930);
        assertEq(closesAt, MON_OCT12_0930 + 6.5 hours);
    }

    function test_holidaysAndEarlyCloses() public view {
        assertFalse(c.isOpen(THANKSGIVING_2026_NOON, true, false));
        assertTrue(c.isOpen(THANKSGIVING_2026_NOON, false, false));
        assertTrue(c.isOpen(NOV27_2026_1300 - 1, true, true));
        assertFalse(c.isOpen(NOV27_2026_1300, true, true));
        assertTrue(c.isOpen(NOV27_2026_1300, true, false)); // early closes not observed
        assertFalse(c.isOpen(DEC24_2026_1300, true, true));
        assertFalse(c.isOpen(XMAS_2026_NOON, true, true));
        assertFalse(c.isOpen(GOOD_FRIDAY_2027_NOON, true, true));
        assertTrue(c.isOpen(GOOD_FRIDAY_2027_NOON, false, true));
        assertFalse(c.isOpen(JUNETEENTH_OBS_2027_NOON, true, true));
        assertTrue(c.isOpen(MON_JAN3_2028_NOON, true, true));
        assertTrue(c.isOpen(JAN1_2031_NOON, true, true)); // past the table: weekdays/hours only
        // Christmas Fri + weekend: next open is Monday Dec 28
        (bool open, uint256 opensAt,) = c.status(DEC24_2026_1300, true, true);
        assertFalse(open);
        assertEq(opensAt, MON_DEC28_2026_0930);
        // early close reported as the session end
        (, , uint256 closesAt) = c.status(NOV27_2026_1300 - 2 hours, true, true);
        assertEq(closesAt, NOV27_2026_1300);
    }

    /// Table sanity: 10 closures a year (9 in 2028), all weekdays, all inside their own year; early
    /// closes are weekdays and never full holidays.
    function test_tableIsConsistent() public view {
        for (uint256 y = 2026; y <= 2030; ++y) {
            uint256 h = c.holidays(y);
            uint256 n;
            while (h != 0) {
                uint256 d = h & 0xffff;
                (uint256 yy,,) = c.civil(d);
                assertEq(yy, y);
                uint256 w = (d + 4) % 7;
                assertTrue(w >= 1 && w <= 5, "weekday");
                h >>= 16;
                n++;
            }
            assertEq(n, y == 2028 ? 9 : 10);
            uint256 e = c.earlyCloses(y);
            while (e != 0) {
                uint256 d = e & 0xffff;
                uint256 w = (d + 4) % 7;
                assertTrue(w >= 1 && w <= 5, "early weekday");
                uint256 hh = c.holidays(y);
                while (hh != 0) {
                    assertTrue(hh & 0xffff != d);
                    hh >>= 16;
                }
                e >>= 16;
            }
        }
        assertEq(c.holidays(2025), 0);
        assertEq(c.holidays(2031), 0);
        // spot checks against the published 2026 NYSE calendar
        assertEq(c.holidays(2026) & 0xffff, c.daysOf(2026, 1, 1));
        assertEq((c.holidays(2026) >> (16 * 6)) & 0xffff, c.daysOf(2026, 7, 3));
        assertEq((c.holidays(2026) >> (16 * 3)) & 0xffff, c.daysOf(2026, 4, 3));
    }

    function testFuzz_civilRoundTrip(uint32 day) public view {
        day = uint32(bound(day, 0, 200_000));
        (uint256 y, uint256 m, uint256 d) = c.civil(day);
        assertEq(c.daysOf(y, m, d), day);
    }

    function testFuzz_statusConsistent(uint64 ts) public view {
        ts = uint64(bound(ts, 1767225600, 1956528000)); // 2026 .. 2031
        (bool open, uint256 opensAt, uint256 closesAt) = c.status(ts, true, true);
        assertEq(open, c.isOpen(ts, true, true));
        assertGe(opensAt, ts);
        assertGt(closesAt, opensAt);
        assertLe(opensAt - ts, 5 days);
        assertTrue(c.isOpen(opensAt, true, true));
        assertTrue(c.isOpen(closesAt - 1, true, true));
        assertFalse(c.isOpen(closesAt, true, true));
        if (!open) assertFalse(c.isOpen(opensAt - 1, true, true));
    }
}

/// Fork: the module in the live hook, on the curve and in the pool. The fork block is Sunday 2026-10-04
/// 20:53 UTC (market closed); launches happen then, trading from Monday.
contract MarketHoursModuleTest is NewModulesBase {
    MarketHoursModule mh;
    MarketHoursSellsOpenModule mhs;
    uint32 mhId;
    uint32 mhsId;

    uint256 constant MON_OCT5_0930 = 1791207000;
    uint256 constant MON_OCT5_1600 = 1791230400;
    uint256 constant TUE_OCT6_0930 = MON_OCT5_0930 + 1 days;
    uint256 constant THANKSGIVING_2026_NOON = 1795712400;
    uint256 constant NOV27_2026_1300 = 1795802400;
    uint256 constant MON_NOV2_0930 = 1793629800;

    function setUp() public override {
        super.setUp();
        mh = new MarketHoursModule(address(hook));
        mhs = new MarketHoursSellsOpenModule(address(hook));
        mhId = modules.addModule(address(mh), '{"name":"Market hours"}');
        mhsId = modules.addModule(address(mhs), '{"name":"Market hours (sells open)"}');
    }

    function _cfg(bool h, bool e) internal pure returns (bytes memory) {
        return abi.encode(MarketHoursBase.Config(h, e));
    }

    /// Launches on Sunday, fills the curve on Monday morning.
    function _launchMh(uint32 id, bytes memory cfg) internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(_one(id), _oneCfg(cfg), 0);
        if (vm.getBlockTimestamp() < MON_OCT5_0930) vm.warp(MON_OCT5_0930 + 10 minutes);
        key = _graduateN(t, 40, 0);
    }

    function test_capabilitiesAndGroups() public view {
        assertEq(mh.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.BLOCKS_SELLS);
        assertEq(mhs.capabilities(), ModuleCaps.BEFORE_SWAP);
        assertEq(mh.conflictGroups(), ModuleCaps.GROUP_SCHEDULE);
        assertEq(mhs.conflictGroups(), ModuleCaps.GROUP_SCHEDULE);
    }

    function test_bothVariantsConflict() public {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (mhId, mhsId);
        (cfgs[0], cfgs[1]) = (_cfg(true, true), _cfg(true, true));
        vm.expectRevert(abi.encodeWithSelector(AvaxHookV2.ModuleConflict.selector, mhsId));
        this.launchExt(ids, cfgs);
    }

    function launchExt(uint32[] memory ids, bytes[] memory cfgs) external {
        _launch(ids, cfgs, 0);
    }

    function test_curveKeepsMarketHours() public {
        HookTokenV2 t = _launch(_one(mhId), _oneCfg(_cfg(true, true)), 0);
        (bool open, uint256 opensAt,) = mh.marketStatus(address(t));
        assertFalse(open);
        assertEq(opensAt, MON_OCT5_0930);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursBase.MarketClosed.selector, MON_OCT5_0930));
        pad.buy{value: 1 ether}(address(t), 0);

        vm.warp(MON_OCT5_0930);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t), 0);
        vm.warp(MON_OCT5_1600);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursBase.MarketClosed.selector, TUE_OCT6_0930));
        pad.sell(address(t), bal / 2, 0);
        vm.warp(TUE_OCT6_0930);
        vm.prank(alice);
        pad.sell(address(t), bal / 2, 0);
    }

    function test_curveSellsOpenVariant() public {
        HookTokenV2 t = _launch(_one(mhsId), _oneCfg(_cfg(true, true)), 0);
        vm.warp(MON_OCT5_0930);
        vm.prank(alice);
        pad.buy{value: 1 ether}(address(t), 0);
        vm.warp(MON_OCT5_1600 + 2 hours);
        uint256 bal = t.balanceOf(alice);
        vm.prank(alice);
        pad.sell(address(t), bal, 0); // sells never close
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursBase.MarketClosed.selector, TUE_OCT6_0930));
        pad.buy{value: 1 ether}(address(t), 0);
    }

    function test_poolKeepsMarketHours() public {
        (HookTokenV2 t, PoolKey memory key) = _launchMh(mhId, _cfg(true, true));
        uint256 got = _routerBuy(alice, t, 1 ether);
        _routerSell(alice, t, got / 2);
        agg.swap(key, true, -int256(0.5 ether)); // aggregators are held to the same hours
        vm.warp(MON_OCT5_1600 - 1);
        _routerSell(alice, t, got / 4);

        // after the bell: both sides closed, aggregators too; wallet transfers still fine
        vm.warp(MON_OCT5_1600);
        assertTrue(_contains(_sellError(alice, t, got / 8), abi.encodeWithSelector(MarketHoursBase.MarketClosed.selector, TUE_OCT6_0930)));
        vm.startPrank(alice);
        t.transfer(bob, 1 ether);
        t.approve(address(agg), got);
        vm.stopPrank();
        vm.expectRevert();
        agg.sellFrom(key, address(t), alice, got / 8);
        assertEq(t.balanceOf(bob), 1 ether);
        assertTrue(_contains(_buyError(bob, t, 1 ether), abi.encodeWithSelector(MarketHoursBase.MarketClosed.selector, TUE_OCT6_0930)));

        vm.warp(TUE_OCT6_0930);
        _routerSell(alice, t, got / 8);
    }

    function test_poolSellsOpenVariant() public {
        (HookTokenV2 t,) = _launchMh(mhsId, _cfg(true, true));
        uint256 got = _routerBuy(alice, t, 1 ether);
        vm.warp(MON_OCT5_1600 + 3 hours); // evening: buys refused, sells fine
        _buyReverts(alice, t, 1 ether);
        _routerSell(alice, t, got);
    }

    function test_holidayAndEarlyCloseInPool() public {
        (HookTokenV2 t,) = _launchMh(mhId, _cfg(true, true));
        (HookTokenV2 t2,) = _launchMh(mhId, _cfg(false, false)); // ignores holidays
        vm.warp(THANKSGIVING_2026_NOON);
        _buyReverts(alice, t, 1 ether);
        _routerBuy(alice, t2, 1 ether); // the pool that ignores holidays trades on Thanksgiving
        vm.warp(NOV27_2026_1300 - 60);
        _routerBuy(alice, t, 1 ether);
        vm.warp(NOV27_2026_1300);
        _buyReverts(alice, t, 1 ether);
        _routerBuy(alice, t2, 1 ether);
    }

    function test_acrossDstEnd() public {
        (HookTokenV2 t,) = _launchMh(mhId, _cfg(true, true));
        vm.warp(MON_NOV2_0930 - 1 hours); // 13:30 UTC: opening time under EDT, 8:30 under EST
        _buyReverts(alice, t, 1 ether);
        vm.warp(MON_NOV2_0930);
        _routerBuy(alice, t, 1 ether);
    }

    function test_gasOfCheck() public {
        (HookTokenV2 t,) = _launchMh(mhId, _cfg(true, true));
        vm.warp(NOV27_2026_1300 - 60); // early-close day: the full table walk
        vm.prank(alice);
        uint256 g = gasleft();
        router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp, "");
        emit log_named_uint("router buy gas, market hours (table day)", g - gasleft());
    }
}
