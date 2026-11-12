// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NewHooksForkBase} from "../NewHooksFork.t.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../../contracts/v2/AvaxHookV2.sol";
import {AlliancesModule} from "../../contracts/v2/modules/AlliancesModule.sol";
import {ArcadeModule} from "../../contracts/v2/modules/ArcadeModule.sol";
import {AutoBurnModule} from "../../contracts/v2/modules/AutoBurnModule.sol";
import {AutoLpModule} from "../../contracts/v2/modules/AutoLpModule.sol";
import {BlockZeroModule} from "../../contracts/v2/modules/BlockZeroModule.sol";
import {BuybackModule} from "../../contracts/v2/modules/BuybackModule.sol";
import {CoupledResonatorModule} from "../../contracts/v2/modules/CoupledResonatorModule.sol";
import {DynamicFeeModule} from "../../contracts/v2/modules/DynamicFeeModule.sol";
import {GraduatedSellCapModule} from "../../contracts/v2/modules/GraduatedSellCapModule.sol";
import {GrudgeModule} from "../../contracts/v2/modules/GrudgeModule.sol";
import {HolderDividendsModule} from "../../contracts/v2/modules/HolderDividendsModule.sol";
import {HolderVestingModule} from "../../contracts/v2/modules/HolderVestingModule.sol";
import {JackpotModule} from "../../contracts/v2/modules/JackpotModule.sol";
import {LastBuyerPotModule} from "../../contracts/v2/modules/LastBuyerPotModule.sol";
import {LockEarnModule} from "../../contracts/v2/modules/LockEarnModule.sol";
import {LpRewardsModule} from "../../contracts/v2/modules/LpRewardsModule.sol";
import {NthBuyPotModule} from "../../contracts/v2/modules/NthBuyPotModule.sol";
import {PingPongModule} from "../../contracts/v2/modules/PingPongModule.sol";
import {ReferralModule} from "../../contracts/v2/modules/ReferralModule.sol";
import {SellTaxDecayModule} from "../../contracts/v2/modules/SellTaxDecayModule.sol";
import {TitheModule} from "../../contracts/v2/modules/TitheModule.sol";
import {UnderwaterModule} from "../../contracts/v2/modules/UnderwaterModule.sol";
import {VolatilityFeeModule} from "../../contracts/v2/modules/VolatilityFeeModule.sol";
import {QuoteRegistry} from "../../contracts/QuoteRegistry.sol";

interface IFeedLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/**
 * Modules against each other on the LIVE v2 stack (Avalanche mainnet fork). Every launch may pick up to 8 of
 * the 55 live modules, and the registry only refuses two modules that claim the same conflict group — so
 * everything across groups can be combined, and almost none of it had ever run together.
 *
 * What this asks of a combination, whatever it is:
 *   - the launch either refuses the set outright (ModuleConflict / BadConfig) or trades;
 *   - a refusal is a module's own error, never a Panic (overflow, division, assert) and never empty
 *     revert data, which is what a module breaking another one looks like from outside;
 *   - the token is never permanently frozen: within a day of attempts some wallet gets a buy through;
 *   - stacked takes leave the trader with something: a buy returns tokens and a sell returns quote.
 *
 *   forge test --match-path test/audit/ModuleComboFork.t.sol -vv     (AVALANCHE_RPC_URL or the public RPC)
 *
 * The 25 newest modules come from NewHooksForkBase (deployed and registered there the way the Safe did it);
 * the older ones are the live addresses in script/v2-state.json, read by `REGISTRY.idOf`.
 */
abstract contract ComboForkBase is NewHooksForkBase {
    // The live modules of the earlier waves (script/v2-state.json).
    address constant TITHE = 0x24A1d06fAdfe7015B602b1BC60A29405a904c8D9;
    address constant HOLDER_DIVIDENDS = 0xAEbb17489026590f54ADaaE1CAa7ecf12cd6E590;
    address constant DYNAMIC_FEE = 0x74Dd9B7fB43beDf0f3A164D133a8002304BaF6F5;
    address constant VOLATILITY_FEE = 0x4054cDdb02A0aa59a38AA9a473e857DE1ba52FF0;
    address constant SELL_TAX_DECAY = 0xcC73C3Dd7F153396182736Bf260d2d08702D364f;
    address constant REFERRAL = 0xf8A74A1D447cF2a38AB9236037544aa030540995;
    address constant LP_REWARDS = 0xFCeA65d4fe0A40907e54e01DE4A39635920DCF54;
    address constant AUTO_BURN = 0x847aF5FF26fCaAC078Ae9d4836400075F02AC202;
    address constant AUTO_LP = 0xab873210Fe4e0b79fa166A96E9D49f98ff0ec81C;
    address constant BUYBACK = 0x6e460dD50E6bD076F5f1C2DadB4cEBf3d1415e66;
    address constant LAST_BUYER_POT = 0x9385632B8AcAdf4537eeE4B55b68925e4F61136b;
    address constant NTH_BUY_POT = 0x110F04E38605E6d714f00675ee6412415a40d6B8;
    address constant PING_PONG = 0xb62231f116E540eA91307411e5ceCA5970C10ba7;

    /// Solidity's Panic(uint256): an overflow, a division by zero or a failed assert inside a module.
    bytes4 constant PANIC = 0x4e487b71;

    struct Mod {
        uint32 id;
        bytes cfg;
        string name;
    }

    /// The pool the random sets are drawn from: a module and a config the registry accepts.
    Mod[] pool;

    /// The live AVAX/USD feed and the answer it carried at the forked block (see _warp).
    address avaxFeed;
    int256 avaxAnswer;
    /// A buy worth $5 in AVAX at the forked block: the floor the pot modules put on their minBuy.
    uint256 fiveDollars;

    function setUp() public virtual override {
        super.setUp();
        (,, avaxFeed) = QuoteRegistry(HOOK.quoteRegistry()).quotes(address(0));
        (, avaxAnswer,,,) = IFeedLike(avaxFeed).latestRoundData();
        fiveDollars = (5e18 * 1e18) / _usd();
        _buildPool();
    }

    /**
     * Warps and re-stamps the price feed. The fork is pinned to one block, so a test that moves days ahead
     * leaves the live signed AVAX/USD answer older than QuoteRegistry.MAX_STALENESS (26 h) and every module
     * that values a trade in USD would revert with StalePrice — an artefact of the fork, not of the modules.
     * The answer stays what the chain really had; only its timestamp follows the clock.
     */
    function _warp(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.mockCall(
            avaxFeed,
            abi.encodeWithSelector(IFeedLike.latestRoundData.selector),
            abi.encode(uint80(1), avaxAnswer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// `m` is live: its id comes from the registry, not from this test's own registrations.
    function _live(address m) internal view returns (uint32 id) {
        id = REGISTRY.idOf(m);
        require(id != 0, "module not registered on the fork");
    }

    function _push(uint32 id, bytes memory cfg, string memory name) internal {
        pool.push(Mod(id, cfg, name));
    }

    /**
     * Modules whose rules depend only on time, blocks, size or price — not on an address being on a list.
     * The list and venue rules (allowlist, blocklist, holder-gated, plague, dex-only, p2p-only) are left out
     * of the random sets on purpose: they refuse an unlisted wallet forever by design, so "somebody gets a
     * buy through" is not a promise they make. They are combined in their own test below.
     */
    function _buildPool() internal {
        // the 25 newest (registered by NewHooksForkBase)
        _push(idOf[address(alliances)], _alliancesCfg(), "alliances");
        _push(idOf[address(antiBundle)], _antiBundleCfg(), "anti-bundle");
        _push(idOf[address(arcade)], abi.encode(ArcadeModule.Config(lightsOut, 60, 10, false, false)), "arcade");
        _push(idOf[address(blockZero)], abi.encode(BlockZeroModule.Config(3, 0)), "block-zero");
        _push(idOf[address(chapters)], _chaptersCfg(), "chapters");
        _push(idOf[address(conviction)], _convictionCfg(), "conviction-cap");
        _push(idOf[address(coupled)], abi.encode(CoupledResonatorModule.Config(100, 25, 60, 60, 1000, 20, 4000)), "coupled-resonator");
        _push(idOf[address(gsc)], abi.encode(GraduatedSellCapModule.Config(50, 100, 300, 10, 86400)), "graduated-sell-caps");
        _push(idOf[address(grudge)], abi.encode(GrudgeModule.Config(5000, 86400, 604800, 0, 0, 0)), "the-grudge");
        _push(idOf[address(vesting)], _vestingCfg(), "holder-vesting");
        _push(idOf[address(jackpot)], abi.encode(JackpotModule.Config(200, 3600, uint96(fiveDollars), 1)), "quantum-jackpot");
        _push(idOf[address(lockEarn)], _lockEarnCfg(), "lock-earn");
        _push(idOf[address(polarity)], _polarityCfg(0, address(0)), "polarity");
        _push(idOf[address(reactive)], _reactiveCfg(address(0)), "reactive-pair");
        _push(idOf[address(redLight)], _redLightCfg(), "red-light");
        _push(idOf[address(resonance)], _resonanceCfg(), "resonance");
        _push(idOf[address(risingFloor)], _risingFloorCfg(), "rising-floor");
        _push(idOf[address(rmw)], _rmwCfg(), "rising-max-wallet");
        _push(idOf[address(underwater)], abi.encode(UnderwaterModule.Config(200, 1, 3600, 2500, 2500)), "underwater");
        // the live earlier waves: everything that takes or sets a fee, the pots, and the turn rule
        _push(_live(TITHE), abi.encode(TitheModule.Config(carol, 500)), "tithe");
        _push(_live(HOLDER_DIVIDENDS), abi.encode(HolderDividendsModule.Config(500)), "holder-dividends");
        _push(_live(DYNAMIC_FEE), abi.encode(DynamicFeeModule.Config(100_000, 5)), "dynamic-fee");
        _push(_live(VOLATILITY_FEE), abi.encode(VolatilityFeeModule.Config(1, 50_000)), "volatility-fee");
        _push(_live(SELL_TAX_DECAY), abi.encode(SellTaxDecayModule.Config(43_200, 200_000)), "sell-tax-decay");
        _push(_live(REFERRAL), abi.encode(ReferralModule.Config(950, 200)), "referral");
        _push(_live(LP_REWARDS), abi.encode(LpRewardsModule.Config(1000)), "lp-rewards");
        _push(_live(AUTO_BURN), abi.encode(AutoBurnModule.Config(500)), "auto-burn");
        _push(_live(AUTO_LP), abi.encode(AutoLpModule.Config(500, uint96(100 ether))), "auto-lp");
        _push(_live(BUYBACK), abi.encode(BuybackModule.Config(1000, uint96(100 ether))), "buyback");
        _push(_live(LAST_BUYER_POT), abi.encode(LastBuyerPotModule.Config(1000, 3600, uint96(fiveDollars))), "last-buyer-pot");
        _push(_live(NTH_BUY_POT), abi.encode(NthBuyPotModule.Config(1000, 3, uint96(fiveDollars))), "nth-buy-pot");
        _push(_live(PING_PONG), abi.encode(PingPongModule.Config(10, 60)), "ping-pong");
    }

    // ---------------------------------------------------------------- picking a set

    /// The conflict groups `id` claims in the registry.
    function _groups(uint32 id) internal view returns (uint32 g) {
        (,, g) = REGISTRY.forLaunch(id);
    }

    /// Up to `k` modules from `pool` for `seed`, skipping any that claims a group already taken.
    function _pick(uint256 seed, uint256 k) internal view returns (uint32[] memory ids, bytes[] memory cfgs, string memory names) {
        uint256 n = pool.length;
        uint32[] memory buf = new uint32[](k);
        bytes[] memory cbuf = new bytes[](k);
        uint256 cnt;
        uint32 seen;
        bool[] memory used = new bool[](n);
        for (uint256 tries; tries < 4 * n && cnt < k; ++tries) {
            uint256 i = uint256(keccak256(abi.encode(seed, tries))) % n;
            if (used[i]) continue;
            used[i] = true;
            uint32 g = _groups(pool[i].id);
            if (g & seen != 0) continue; // the registry would refuse this one
            seen |= g;
            buf[cnt] = pool[i].id;
            cbuf[cnt] = pool[i].cfg;
            names = cnt == 0 ? pool[i].name : string.concat(names, " + ", pool[i].name);
            ++cnt;
        }
        ids = new uint32[](cnt);
        cfgs = new bytes[](cnt);
        for (uint256 j; j < cnt; ++j) (ids[j], cfgs[j]) = (buf[j], cbuf[j]);
    }

    // ---------------------------------------------------------------- invariants

    /// A refusal has to be a module saying no, not a module breaking: never a Panic, never empty.
    function _assertSaneRefusal(bytes memory err, string memory what) internal pure {
        assertGt(err.length, 3, string.concat(what, ": empty revert data (out of gas or a bare revert)"));
        assertFalse(_has(err, PANIC), string.concat(what, ": Panic inside a module (overflow / division / assert)"));
    }

    /// Tries a curve buy; returns whether it went through and the refusal, which has to be a sane one.
    function _tryCurveBuy(address who, HookTokenV2 t, uint256 amt, string memory what)
        internal
        returns (bool ok, bytes memory err)
    {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        try PAD.buy{value: amt}(address(t), 0) {
            return (true, "");
        } catch (bytes memory e) {
            _assertSaneRefusal(e, what);
            return (false, e);
        }
    }

    function _tryCurveSell(address who, HookTokenV2 t, uint256 amt, string memory what) internal returns (bool) {
        vm.prank(who);
        try PAD.sell(address(t), amt, 0) {
            return true;
        } catch (bytes memory err) {
            _assertSaneRefusal(err, what);
            return false;
        }
    }

    /**
     * Nothing locks the curve for good: over a day of attempts (an hour and two blocks apart, round robin
     * over wallets), some buy gets through — and every refusal on the way is a module's own error.
     *
     * The size adapts, because a cap is not a freeze: early on the curve even a small amount of quote buys a
     * large share of the supply, so a per-buy or per-wallet cap refuses it rightly. Every refusal quarters
     * the next attempt, down to a thousandth of the first. If even that is refused for a day, the set really
     * has shut the token, and the last refusal is printed so it can be read.
     */
    function _assertEventuallyTradeable(HookTokenV2 t, string memory names) internal returns (uint256 buys) {
        uint256 amt = _target(t) / 2000 + 1;
        uint256 least = _target(t) / 2_000_000 + 1;
        bytes memory lastErr;
        for (uint256 i; i < 24 && !PAD.getLaunch(address(t)).complete; ++i) {
            _warp(1 hours);
            vm.roll(vm.getBlockNumber() + 2);
            (bool ok, bytes memory err) = _tryCurveBuy(_w(i % 6), t, amt, names);
            if (ok) {
                ++buys;
            } else {
                lastErr = err;
                uint256 next = amt / 4;
                amt = next > least ? next : least;
            }
        }
        if (buys == 0) emit log_named_bytes(string.concat("last refusal [", names, "]"), lastErr);
        assertGt(buys, 0, string.concat("frozen curve: no buy in 24 hours of attempts [", names, "]"));
    }
}

// ==================================================================== every fee and cut at once

/// forge-config: default.isolate = true
contract ComboFeeStackTest is ComboForkBase {
    /**
     * Eight modules that all take or raise a fee, each at the top of its documented range: tithe 5% and
     * holder dividends 5% of every trade, dynamic fee up to 10%, volatility fee up to 5%, a 20% sell tax at
     * open, a 9.5% referral fee, 10% of fees to LPs and a 5% auto-burn. None of them claims a conflict group,
     * so the picker allows exactly this. The hook caps the total LP fee at MAX_TOTAL_FEE_PIPS and scales the
     * credits down together, and this is what that is worth in practice: the trader still gets something.
     */
    function test_feeStackStillTrades() public {
        uint32[] memory ids = new uint32[](8);
        bytes[] memory cfgs = new bytes[](8);
        (ids[0], cfgs[0]) = (_live(TITHE), abi.encode(TitheModule.Config(carol, 500)));
        (ids[1], cfgs[1]) = (_live(HOLDER_DIVIDENDS), abi.encode(HolderDividendsModule.Config(500)));
        (ids[2], cfgs[2]) = (_live(DYNAMIC_FEE), abi.encode(DynamicFeeModule.Config(100_000, 5)));
        (ids[3], cfgs[3]) = (_live(VOLATILITY_FEE), abi.encode(VolatilityFeeModule.Config(1, 50_000)));
        (ids[4], cfgs[4]) = (_live(SELL_TAX_DECAY), abi.encode(SellTaxDecayModule.Config(43_200, 200_000)));
        (ids[5], cfgs[5]) = (_live(REFERRAL), abi.encode(ReferralModule.Config(950, 200)));
        (ids[6], cfgs[6]) = (_live(LP_REWARDS), abi.encode(LpRewardsModule.Config(1000)));
        (ids[7], cfgs[7]) = (_live(AUTO_BURN), abi.encode(AutoBurnModule.Config(500)));
        HookTokenV2 t = _launchAs(creator, ids, cfgs);

        _fill(t, 12, 6);
        assertTrue(_graduated(t), "graduated with eight fee modules");

        uint256 got = _routerBuy(alice, t, _small(t) * 5);
        assertGt(got, 0, "a buy under every fee still returns tokens");
        uint256 before = alice.balance;
        _routerSell(alice, t, got / 2);
        assertGt(alice.balance, before, "a sell under every fee still returns AVAX");
    }
}

// ==================================================================== pots and the modules that touch the pool

/// forge-config: default.isolate = true
contract ComboPotsAndPoolTest is ComboForkBase {
    /**
     * Everything that moves quote of its own accord in one launch: the three pots, auto-LP compounding,
     * the buyback, dividends and the auto-burn. They all take their share of the same trade, so this is the
     * case the hook's shared cap (`maxCut`, scaled down together rather than reverting) is there for.
     */
    function test_potsAndPoolModules() public {
        uint32[] memory ids = new uint32[](7);
        bytes[] memory cfgs = new bytes[](7);
        (ids[0], cfgs[0]) = (_live(LAST_BUYER_POT), abi.encode(LastBuyerPotModule.Config(1000, 3600, uint96(fiveDollars))));
        (ids[1], cfgs[1]) = (_live(NTH_BUY_POT), abi.encode(NthBuyPotModule.Config(1000, 3, uint96(fiveDollars))));
        (ids[2], cfgs[2]) = (idOf[address(jackpot)], abi.encode(JackpotModule.Config(200, 3600, uint96(fiveDollars), 1)));
        (ids[3], cfgs[3]) = (_live(AUTO_LP), abi.encode(AutoLpModule.Config(500, uint96(100 ether))));
        (ids[4], cfgs[4]) = (_live(BUYBACK), abi.encode(BuybackModule.Config(1000, uint96(100 ether))));
        (ids[5], cfgs[5]) = (_live(HOLDER_DIVIDENDS), abi.encode(HolderDividendsModule.Config(500)));
        (ids[6], cfgs[6]) = (_live(AUTO_BURN), abi.encode(AutoBurnModule.Config(500)));
        HookTokenV2 t = _launchAs(creator, ids, cfgs);

        _fill(t, 12, 6);
        uint256 got = _routerBuy(alice, t, _small(t) * 5);
        _routerSell(alice, t, got / 2);
        _routerBuy(bob, t, _small(t) * 5);
        _routerSell(_w(0), t, t.balanceOf(_w(0)) / 4);
        assertGt(t.totalSupply(), 0, "the token survived every taker");
    }
}

// ==================================================================== a turn rule next to a sell lock

/// forge-config: default.isolate = true
contract ComboDeadlockTest is ComboForkBase {
    /**
     * Ping pong (buys and sells must alternate) next to holder vesting (holders cannot sell yet) and the
     * graduated sell caps. Different groups, so the registry allows it, and between them they can stall the
     * pool: it is the sell's turn and nobody is allowed to sell. The claim under test is that the stall is
     * bounded — the turn frees up after the configured timeout and buys resume — not that it cannot happen.
     */
    function test_turnRuleWithSellLockUnlocksItself() public {
        uint32[] memory ids = new uint32[](3);
        bytes[] memory cfgs = new bytes[](3);
        (ids[0], cfgs[0]) = (_live(PING_PONG), abi.encode(PingPongModule.Config(10, 3600))); // 1 h timeout
        (ids[1], cfgs[1]) = (idOf[address(vesting)], _vestingCfg()); // nothing sellable for a day
        (ids[2], cfgs[2]) = (idOf[address(gsc)], abi.encode(GraduatedSellCapModule.Config(50, 100, 300, 10, 86400)));
        HookTokenV2 t = _launchAs(creator, ids, cfgs);

        uint256 buys = _assertEventuallyTradeable(t, "ping-pong + holder-vesting + graduated-sell-caps");
        emit log_named_uint("curve buys that got through the turn rule and the lock", buys);

        // the turn is the buy's again after the timeout, every time: the stall never becomes permanent
        _warp(2 hours);
        vm.roll(vm.getBlockNumber() + 1);
        (bool passed,) = _tryCurveBuy(alice, t, _target(t) / 2000 + 1, "after the timeout");
        assertTrue(passed, "a buy must pass once the turn frees up");
    }
}

// ==================================================================== eight of the newest, and what they cost

/// forge-config: default.isolate = true
contract ComboHeavyEightTest is ComboForkBase {
    /**
     * Eight of the newest modules in one launch, the heaviest ones that can sit together (the arcade keeps a
     * game, polarity and underwater read the pair's price, the grudge and rising floor keep their own
     * ledgers). The earlier wave's eight-module gas figures said nothing about these.
     */
    function test_heavyEightFromTheNewWave() public {
        uint32[] memory ids = new uint32[](8);
        bytes[] memory cfgs = new bytes[](8);
        // capBps 50%: the arcade is in this set for the work it does per swap, not for its holding cap —
        // at the default 0.1% the curve can only be filled by wallets that have played the game first.
        (ids[0], cfgs[0]) = (idOf[address(arcade)], abi.encode(ArcadeModule.Config(lightsOut, 60, 5000, false, false)));
        (ids[1], cfgs[1]) = (idOf[address(polarity)], _polarityCfg(0, address(0)));
        (ids[2], cfgs[2]) = (idOf[address(underwater)], abi.encode(UnderwaterModule.Config(200, 1, 3600, 2500, 2500)));
        (ids[3], cfgs[3]) = (idOf[address(risingFloor)], _risingFloorCfg());
        (ids[4], cfgs[4]) = (idOf[address(grudge)], abi.encode(GrudgeModule.Config(5000, 86400, 604800, 0, 0, 0)));
        (ids[5], cfgs[5]) = (idOf[address(antiBundle)], _antiBundleCfg());
        (ids[6], cfgs[6]) = (idOf[address(blockZero)], abi.encode(BlockZeroModule.Config(3, 0)));
        (ids[7], cfgs[7]) = (idOf[address(jackpot)], abi.encode(JackpotModule.Config(200, 3600, uint96(fiveDollars), 1)));
        HookTokenV2 t = _launchAs(creator, ids, cfgs);

        _fillCapped(t, 19_000_000 ether, 8, 60, 4);
        assertTrue(_graduated(t), "graduated with eight of the newest");

        uint256 amt = _small(t) * 5;
        vm.deal(alice, alice.balance + amt);
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 got = ROUTER.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "");
        emit log_named_uint("8 of the newest: router buy gas", g - gasleft());
        assertGt(got, 0, "buy returns tokens");

        vm.startPrank(alice);
        t.approve(address(ROUTER), got / 2);
        g = gasleft();
        ROUTER.sell(address(t), got / 2, 0, block.timestamp, "");
        emit log_named_uint("8 of the newest: router sell gas", g - gasleft());
        vm.stopPrank();
    }
}

// ==================================================================== random eights

/// forge-config: default.isolate = true
contract ComboRandomEightsTest is ComboForkBase {
    /**
     * Eight modules drawn from the pool for a fixed list of seeds (reproducible, not fuzzed: a fork run per
     * seed is expensive). The registry's conflict groups are applied while picking, so every set is one a
     * launcher could really choose on the form. Each set has to launch, refuse only with its own errors, and
     * leave the curve usable.
     */
    function test_randomEights() public {
        uint256[8] memory seeds = [uint256(1), 2, 3, 5, 8, 13, 21, 34];
        for (uint256 s; s < seeds.length; ++s) {
            (uint32[] memory ids, bytes[] memory cfgs, string memory names) = _pick(seeds[s], 8);
            assertEq(ids.length, 8, "picked eight");
            emit log_named_string(string.concat("seed ", vm.toString(seeds[s])), names);
            HookTokenV2 t = _launchAs(creator, ids, cfgs);
            uint256 buys = _assertEventuallyTradeable(t, names);
            // a holder sells: it may be refused by a lock or a cap, but only with a module's own error
            address h = _w(0);
            uint256 bal = t.balanceOf(h);
            if (bal > 0) _tryCurveSell(h, t, bal / 4, string.concat("sell [", names, "]"));
            emit log_named_uint("  buys through", buys);
        }
    }
}
