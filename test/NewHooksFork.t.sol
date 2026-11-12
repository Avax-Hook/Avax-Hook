// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";
import {AvaxHookRouterV2} from "../contracts/v2/AvaxHookRouterV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {HookTokenV2} from "../contracts/v2/HookTokenV2.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ArcadeScores} from "../contracts/v2/arcade/ArcadeScores.sol";
import {LightsOutGame} from "../contracts/v2/arcade/LightsOutGame.sol";
import {Game2048} from "../contracts/v2/arcade/Game2048.sol";
import {AlliancesModule} from "../contracts/v2/modules/AlliancesModule.sol";
import {AllowlistModule} from "../contracts/v2/modules/AllowlistModule.sol";
import {AntiBundleModule} from "../contracts/v2/modules/AntiBundleModule.sol";
import {ArcadeModule} from "../contracts/v2/modules/ArcadeModule.sol";
import {BlockZeroModule} from "../contracts/v2/modules/BlockZeroModule.sol";
import {BlocklistModule} from "../contracts/v2/modules/BlocklistModule.sol";
import {ChaptersModule} from "../contracts/v2/modules/ChaptersModule.sol";
import {ConvictionCapModule} from "../contracts/v2/modules/ConvictionCapModule.sol";
import {CoupledResonatorModule} from "../contracts/v2/modules/CoupledResonatorModule.sol";
import {DexOnlyModule} from "../contracts/v2/modules/DexOnlyModule.sol";
import {GraduatedSellCapModule} from "../contracts/v2/modules/GraduatedSellCapModule.sol";
import {GrudgeModule} from "../contracts/v2/modules/GrudgeModule.sol";
import {HolderGatedModule} from "../contracts/v2/modules/HolderGatedModule.sol";
import {HolderVestingModule} from "../contracts/v2/modules/HolderVestingModule.sol";
import {JackpotModule} from "../contracts/v2/modules/JackpotModule.sol";
import {LockEarnModule} from "../contracts/v2/modules/LockEarnModule.sol";
import {P2pOnlyModule} from "../contracts/v2/modules/P2pOnlyModule.sol";
import {PlagueModule} from "../contracts/v2/modules/PlagueModule.sol";
import {PolarityModule} from "../contracts/v2/modules/PolarityModule.sol";
import {ReactivePairModule} from "../contracts/v2/modules/ReactivePairModule.sol";
import {RedLightModule} from "../contracts/v2/modules/RedLightModule.sol";
import {ResonanceModule} from "../contracts/v2/modules/ResonanceModule.sol";
import {RisingFloorModule} from "../contracts/v2/modules/RisingFloorModule.sol";
import {RisingMaxWalletModule} from "../contracts/v2/modules/RisingMaxWalletModule.sol";
import {UnderwaterModule} from "../contracts/v2/modules/UnderwaterModule.sol";

interface ICurrentCap {
    function currentCap(address token) external view returns (uint256);
}

/// The 25 new hook modules end to end on the LIVE v2 stack (Avalanche mainnet fork): each is deployed the way
/// script/DeployNewHooks.s.sol deploys it (owner = the Safe), the Safe registers it (and wires ArcadeScores and
/// the Underwater keeper), then a token launches on the live HookLaunchpadV2 with that module alone and its
/// default config from config/hook-modules/<id>.json. Every token trades on the curve with several wallets
/// (respecting the rule), graduates, and does a router buy and a router sell; each test also checks one
/// refusal the rule promises. Combos and conflict groups at the end.
///
///   forge test --match-path test/NewHooksFork.t.sol -vv            (AVALANCHE_RPC_URL or the public RPC)
///
/// Isolated (every concrete contract below): several rules count per transaction (transient storage), so every
/// top-level call must be its own transaction.
abstract contract NewHooksForkBase is Test {
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    HookLaunchpadV2 constant PAD = HookLaunchpadV2(payable(0x922A73Bd8aC4db8729aADE7a09288Da536058F02));
    AvaxHookV2 constant HOOK = AvaxHookV2(payable(0x179278C7ECD2cFbc003D76985Ba05f11DDc36ACc));
    AvaxHookRouterV2 constant ROUTER = AvaxHookRouterV2(payable(0xC8B2b67A1E286f74648A705617d54a0415fc651a));
    HookModuleRegistry constant REGISTRY = HookModuleRegistry(0xA84Eb2215c88e76048552471E1a486Ae68762286);
    address constant HOOK_TOKEN = 0x898D93e5BF6ee61a03f50CB0cdBF9C3751dA8Dc7;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    Currency constant NATIVE = Currency.wrap(address(0));
    uint256 constant SUPPLY = 1_000_000_000 ether;
    /// Pinned so forge's RPC cache makes reruns fast; NEW_HOOKS_FORK_BLOCK=0 forks the latest block.
    uint256 constant FORK_BLOCK = 97_885_000;

    ArcadeScores scores;
    address lightsOut;
    address g2048;
    AlliancesModule alliances;
    AllowlistModule allowlist;
    AntiBundleModule antiBundle;
    ArcadeModule arcade;
    BlockZeroModule blockZero;
    BlocklistModule blocklist;
    ChaptersModule chapters;
    ConvictionCapModule conviction;
    CoupledResonatorModule coupled;
    DexOnlyModule dexOnly;
    GraduatedSellCapModule gsc;
    GrudgeModule grudge;
    HolderGatedModule holderGated;
    HolderVestingModule vesting;
    JackpotModule jackpot;
    LockEarnModule lockEarn;
    P2pOnlyModule p2p;
    PlagueModule plague;
    PolarityModule polarity;
    ReactivePairModule reactive;
    RedLightModule redLight;
    ResonanceModule resonance;
    RisingFloorModule risingFloor;
    RisingMaxWalletModule rmw;
    UnderwaterModule underwater;
    mapping(address => uint32) idOf;

    address creator = makeAddr("nh-creator");
    address keeper = makeAddr("nh-keeper");
    address alice = makeAddr("nh-alice");
    address bob = makeAddr("nh-bob");
    address carol = makeAddr("nh-carol");

    function setUp() public virtual {
        string memory rpc = vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc"));
        uint256 blk = vm.envOr("NEW_HOOKS_FORK_BLOCK", FORK_BLOCK);
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);

        address hook = address(HOOK);
        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (address(0), USDC, USDT);
        // exactly as DeployNewHooks.s.sol (owner = the Safe)
        scores = new ArcadeScores(SAFE);
        lightsOut = address(new LightsOutGame());
        g2048 = address(new Game2048());
        alliances = new AlliancesModule(hook);
        allowlist = new AllowlistModule(hook);
        antiBundle = new AntiBundleModule(hook);
        arcade = new ArcadeModule(hook, scores);
        blockZero = new BlockZeroModule(hook);
        blocklist = new BlocklistModule(hook);
        chapters = new ChaptersModule(hook);
        conviction = new ConvictionCapModule(hook);
        coupled = new CoupledResonatorModule(hook);
        dexOnly = new DexOnlyModule(hook);
        gsc = new GraduatedSellCapModule(hook);
        grudge = new GrudgeModule(hook);
        holderGated = new HolderGatedModule(hook);
        vesting = new HolderVestingModule(hook);
        jackpot = new JackpotModule(hook);
        lockEarn = new LockEarnModule(hook);
        p2p = new P2pOnlyModule(hook);
        plague = new PlagueModule(hook);
        polarity = new PolarityModule(hook, assets);
        reactive = new ReactivePairModule(hook);
        redLight = new RedLightModule(hook);
        resonance = new ResonanceModule(hook);
        risingFloor = new RisingFloorModule(hook);
        rmw = new RisingMaxWalletModule(hook);
        underwater = new UnderwaterModule(hook, SAFE);

        // the Safe batch: addModule for each, ArcadeScores games + binder, Underwater keeper
        vm.startPrank(SAFE);
        _add(address(alliances), "alliances");
        _add(address(allowlist), "allowlist");
        _add(address(antiBundle), "anti-bundle");
        _add(address(arcade), "arcade");
        _add(address(blockZero), "block-zero");
        _add(address(blocklist), "blocklist");
        _add(address(chapters), "chapters");
        _add(address(conviction), "conviction-cap");
        _add(address(coupled), "coupled-resonator");
        _add(address(dexOnly), "dex-only");
        _add(address(gsc), "graduated-sell-caps");
        _add(address(grudge), "the-grudge");
        _add(address(holderGated), "holder-gated");
        _add(address(vesting), "holder-vesting");
        _add(address(jackpot), "quantum-jackpot");
        _add(address(lockEarn), "lock-earn");
        _add(address(p2p), "p2p-only");
        _add(address(plague), "plague");
        _add(address(polarity), "polarity");
        _add(address(reactive), "reactive-pair");
        _add(address(redLight), "red-light");
        _add(address(resonance), "resonance");
        _add(address(risingFloor), "rising-floor");
        _add(address(rmw), "rising-max-wallet");
        _add(address(underwater), "underwater");
        scores.setGame(lightsOut, true);
        scores.setGame(g2048, true);
        scores.setBinder(address(arcade), true);
        underwater.setKeeper(keeper);
        vm.stopPrank();
    }

    function _add(address impl, string memory id) internal {
        idOf[impl] = REGISTRY.addModule(impl, string.concat('{"id":"', id, '"}'));
    }

    // ---------------------------------------------------------------- default configs (config/hook-modules/*.json)

    function _alliancesCfg() internal pure returns (bytes memory) {
        return abi.encode(AlliancesModule.Config(200, 1000 ether, 1000 ether, new address[](0), new address[](0)));
    }

    function _antiBundleCfg() internal pure returns (bytes memory) {
        return abi.encode(AntiBundleModule.Config(3, 300, 5));
    }

    function _redLightCfg() internal pure returns (bytes memory) {
        return abi.encode(RedLightModule.Config(60, 6000, 5, true));
    }

    function _risingFloorCfg() internal pure returns (bytes memory) {
        return abi.encode(RisingFloorModule.Config(100));
    }

    function _lockEarnCfg() internal pure returns (bytes memory) {
        return abi.encode(LockEarnModule.Config(200, 86400));
    }

    function _vestingCfg() internal pure returns (bytes memory) {
        return abi.encode(HolderVestingModule.Config(86400, 5, 86400, 1000, 86400));
    }

    function _resonanceCfg() internal pure returns (bytes memory) {
        return abi.encode(ResonanceModule.Config(100, 25, 60, 50, 4000, 500, 500));
    }

    function _convictionCfg() internal pure returns (bytes memory) {
        return abi.encode(ConvictionCapModule.Config(10, 10, 86400, 200, 0));
    }

    function _chaptersCfg() internal pure returns (bytes memory) {
        return abi.encode(ChaptersModule.Config(100, 1600, 100_000_000 ether));
    }

    function _rmwCfg() internal pure returns (bytes memory) {
        return abi.encode(RisingMaxWalletModule.Config(10, 0, 10, 300));
    }

    function _reactiveCfg(address partner) internal pure returns (bytes memory) {
        return abi.encode(ReactivePairModule.Config(100, 25, 400, 5000, 100, 3600, partner));
    }

    function _polarityCfg(uint8 side, address partner) internal pure returns (bytes memory) {
        return abi.encode(PolarityModule.Config(address(0), side, 20, 100, partner));
    }

    // ---------------------------------------------------------------- launch / trade helpers

    function _one(address m, bytes memory cfg) internal view returns (uint32[] memory ids, bytes[] memory cfgs) {
        ids = new uint32[](1);
        cfgs = new bytes[](1);
        (ids[0], cfgs[0]) = (idOf[m], cfg);
    }

    function _args(uint32[] memory ids, bytes[] memory cfgs) internal pure returns (HookLaunchpadV2.LaunchArgs memory a) {
        a.name = "New Hook";
        a.symbol = "NHOOK";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 50, baseFeePips: 0});
        a.moduleIds = ids;
        a.moduleConfigs = cfgs;
    }

    function _launchAs(address who, uint32[] memory ids, bytes[] memory cfgs) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a = _args(ids, cfgs);
        uint256 fee = PAD.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        t = HookTokenV2(PAD.launch{value: fee}(a));
    }

    function _launch(address m, bytes memory cfg) internal returns (HookTokenV2 t) {
        (uint32[] memory ids, bytes[] memory cfgs) = _one(m, cfg);
        t = _launchAs(creator, ids, cfgs);
    }

    function launchExt(address who, uint32[] memory ids, bytes[] memory cfgs) external {
        _launchAs(who, ids, cfgs);
    }

    function _target(HookTokenV2 t) internal view returns (uint256) {
        return uint256(PAD.getLaunch(address(t)).target);
    }

    function _graduated(HookTokenV2 t) internal view returns (bool) {
        return PAD.getLaunch(address(t)).graduated;
    }

    /// Curve-filling wallet i (shared by every test so the fork fetches each account once).
    function _w(uint256 i) internal pure returns (address) {
        return address(uint160(0xF1E1D000 + i));
    }

    function _curveBuy(address who, HookTokenV2 t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        PAD.buy{value: amt}(address(t), 0);
    }

    function _curveBuyErr(address who, HookTokenV2 t, uint256 amt) internal returns (bytes memory err) {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        try PAD.buy{value: amt}(address(t), 0) {
            revert("curve buy did not revert");
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _curveSell(address who, HookTokenV2 t, uint256 amt) internal {
        vm.prank(who);
        PAD.sell(address(t), amt, 0);
    }

    /// AVAX in (gross) for a curve buy that receives about `tokens` (2% margin below).
    function _grossFor(HookTokenV2 t, uint256 tokens) internal view returns (uint256) {
        HookLaunchpadV2.Launch memory l = PAD.getLaunch(address(t));
        uint256 x = uint256(l.virtualQuote) + l.reserve;
        uint256 y = uint256(l.virtualTokens) - l.tokensSold;
        uint256 net = (x * tokens) / (y - tokens);
        return (net * 9_700) / (10_000 - 30 - l.creatorFeeBps);
    }

    /// Fills the curve with `n` equal buys (target / n) from wallets _w(0.. nWallets-1), round robin.
    function _fill(HookTokenV2 t, uint256 n, uint256 nWallets) internal {
        uint256 chunk = _target(t) / n + 1;
        for (uint256 i; i < 3 * n && !PAD.getLaunch(address(t)).complete; ++i) {
            _curveBuy(_w(i % nWallets), t, chunk);
        }
        assertTrue(_graduated(t), "graduated");
    }

    /// Fills the curve with buys that each receive at most `maxTokens`, from wallets round robin, `spacing`
    /// seconds and `blocks` blocks apart.
    function _fillCapped(HookTokenV2 t, uint256 maxTokens, uint256 nWallets, uint256 spacing, uint256 blocks) internal {
        for (uint256 i; i < 3000 && !PAD.getLaunch(address(t)).complete; ++i) {
            if (spacing > 0) vm.warp(vm.getBlockTimestamp() + spacing);
            if (blocks > 0) vm.roll(vm.getBlockNumber() + blocks);
            _curveBuy(_w(i % nWallets), t, _grossFor(t, maxTokens));
        }
        assertTrue(_graduated(t), "graduated");
    }

    /// Fills the curve under a per-buy cap read from the module (currentCap), 1 s between buys.
    function _fillByCap(HookTokenV2 t, address m, uint256 nWallets) internal returns (uint256 buys) {
        for (; buys < 3000 && !PAD.getLaunch(address(t)).complete; ++buys) {
            vm.warp(vm.getBlockTimestamp() + 1);
            uint256 cap = ICurrentCap(m).currentCap(address(t));
            _curveBuy(_w(buys % nWallets), t, _grossFor(t, (cap * 85) / 100));
        }
        assertTrue(_graduated(t), "graduated");
    }

    function _routerBuy(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        out = ROUTER.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "");
        assertGt(out, 0, "router buy got tokens");
    }

    function _routerSell(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(who);
        t.approve(address(ROUTER), amt);
        out = ROUTER.sell(address(t), amt, 0, block.timestamp, "");
        vm.stopPrank();
        assertGt(out, 0, "router sell got AVAX");
    }

    function _buyErr(address who, HookTokenV2 t, uint256 amt) internal returns (bytes memory err) {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        try ROUTER.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "") {
            revert("router buy did not revert");
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _sellErr(address who, HookTokenV2 t, uint256 amt) internal returns (bytes memory err) {
        vm.startPrank(who);
        t.approve(address(ROUTER), amt);
        try ROUTER.sell(address(t), amt, 0, block.timestamp, "") {
            revert("router sell did not revert");
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _sendErr(HookTokenV2 t, address from, address to, uint256 amt) internal returns (bytes memory err) {
        vm.prank(from);
        try t.transfer(to, amt) {
            revert("transfer did not revert");
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _send(HookTokenV2 t, address from, address to, uint256 amt) internal {
        vm.prank(from);
        t.transfer(to, amt);
    }

    /// Router buy + router sell after graduation (the sell is a small slice of the seller's bag).
    function _roundTrip(HookTokenV2 t, address buyer, uint256 amt) internal returns (uint256 got) {
        got = _routerBuy(buyer, t, amt);
        _routerSell(buyer, t, got / 2);
    }

    /// A small pool buy: about 0.1% of the curve's target in AVAX.
    function _small(HookTokenV2 t) internal view returns (uint256) {
        return _target(t) / 1000;
    }

    function _has(bytes memory err, bytes4 sel) internal pure returns (bool) {
        bytes memory needle = abi.encodePacked(sel);
        if (err.length < 4) return false;
        for (uint256 i; i + 4 <= err.length; ++i) {
            if (err[i] == needle[0] && err[i + 1] == needle[1] && err[i + 2] == needle[2] && err[i + 3] == needle[3]) {
                return true;
            }
        }
        return false;
    }

    function _usd() internal view returns (uint256) {
        return QuoteRegistry(HOOK.quoteRegistry()).usdPrice(address(0));
    }
}

// ==================================================================== lists and access

/// forge-config: default.isolate = true
contract NewHooksForkListsTest is NewHooksForkBase {
    /// holder-gated: gate = the HOOK token, 1000 HOOK, forever. Traders hold HOOK (dealt).
    function test_holderGated() public {
        HookTokenV2 t = _launch(address(holderGated), abi.encode(HolderGatedModule.Config(HOOK_TOKEN, 1000 ether, 0)));
        for (uint256 i; i < 20; ++i) deal(HOOK_TOKEN, _w(i), 1000 ether);
        deal(HOOK_TOKEN, alice, 1000 ether);
        // refusal: no HOOK, no buy (curve and pool)
        assertTrue(_has(_curveBuyErr(bob, t, 1 ether), HolderGatedModule.GateNotHeld.selector), "curve gate");
        _fill(t, 40, 20);
        assertTrue(_has(_buyErr(bob, t, _small(t)), HolderGatedModule.GateNotHeld.selector), "pool gate");
        uint256 got = _roundTrip(t, alice, _small(t));
        assertTrue(_has(_sendErr(t, alice, bob, got / 4), HolderGatedModule.GateNotHeld.selector), "send gate");
    }

    /// blocklist: one random address.
    function test_blocklist() public {
        address banned = address(uint160(uint256(keccak256("nh-banned"))));
        address[] memory l = new address[](1);
        l[0] = banned;
        HookTokenV2 t = _launch(address(blocklist), abi.encode(BlocklistModule.Config(l)));
        assertTrue(_has(_curveBuyErr(banned, t, 1 ether), BlocklistModule.ReceiverBlocked.selector), "curve");
        _fill(t, 40, 20);
        assertTrue(_has(_buyErr(banned, t, _small(t)), BlocklistModule.ReceiverBlocked.selector), "pool");
        uint256 got = _roundTrip(t, alice, _small(t));
        assertTrue(_has(_sendErr(t, alice, banned, got / 4), BlocklistModule.ReceiverBlocked.selector), "send");
    }

    /// allowlist: list = the test traders (+ a Merkle root for dave and erin, who prove), 7 days.
    function test_allowlist() public {
        address dave = makeAddr("nh-dave");
        address erin = makeAddr("nh-erin");
        bytes32 la = allowlist.leaf(dave);
        bytes32 lb = allowlist.leaf(erin);
        bytes32 root = la < lb ? keccak256(abi.encode(la, lb)) : keccak256(abi.encode(lb, la));
        address[] memory list = new address[](21);
        for (uint256 i; i < 20; ++i) list[i] = _w(i);
        list[20] = alice;
        HookTokenV2 t = _launch(address(allowlist), abi.encode(AllowlistModule.Config(list, root, 604800)));
        // refusal: not on the list
        assertTrue(_has(_curveBuyErr(bob, t, 1 ether), AllowlistModule.NotAllowed.selector), "curve");
        // dave proves in his curve buy
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = lb;
        vm.deal(dave, 1 ether);
        vm.prank(dave);
        PAD.buyWithData{value: 1 ether}(address(t), 1 ether, 0, address(0), abi.encode(proof));
        assertTrue(allowlist.isAllowed(address(t), dave));
        _fill(t, 40, 20);
        assertTrue(_has(_buyErr(bob, t, _small(t)), AllowlistModule.NotAllowed.selector), "pool");
        // erin proves permissionlessly, then receives
        proof[0] = la;
        vm.prank(bob);
        allowlist.prove(address(t), erin, proof);
        uint256 got = _roundTrip(t, alice, _small(t));
        _send(t, alice, erin, got / 4);
        assertTrue(_has(_sendErr(t, alice, bob, got / 8), AllowlistModule.NotAllowed.selector), "send");
        // after the window anyone can buy
        vm.warp(vm.getBlockTimestamp() + 604800);
        _routerBuy(bob, t, _small(t));
    }

    /// plague: 100k tokens infect, 7 days. Curve buyers are infected; pool buys need it.
    function test_plague() public {
        HookTokenV2 t = _launch(address(plague), abi.encode(PlagueModule.Config(100_000 ether, 604800)));
        _fill(t, 40, 20);
        assertTrue(plague.infected(address(t), _w(0)));
        assertTrue(_has(_buyErr(bob, t, _small(t)), PlagueModule.NotInfected.selector), "uninfected");
        _roundTrip(t, _w(1), _small(t));
        _send(t, _w(2), bob, 100_000 ether); // infects bob
        assertTrue(plague.infected(address(t), bob));
        _roundTrip(t, bob, _small(t));
    }

    /// dex-only: forever. Wallet-to-wallet sends refused, swaps fine.
    function test_dexOnly() public {
        HookTokenV2 t = _launch(address(dexOnly), abi.encode(DexOnlyModule.Config(0)));
        _fill(t, 40, 20);
        uint256 got = _roundTrip(t, alice, _small(t));
        assertTrue(_has(_sendErr(t, alice, bob, got / 4), DexOnlyModule.WalletToWallet.selector), "w2w");
    }

    /// p2p-only: 1 day with no pool swaps after the pool opens.
    function test_p2pOnly() public {
        HookTokenV2 t = _launch(address(p2p), abi.encode(P2pOnlyModule.Config(86400)));
        _fill(t, 40, 20);
        assertTrue(_has(_buyErr(alice, t, _small(t)), P2pOnlyModule.PeerToPeerOnly.selector), "pool closed");
        assertTrue(_has(_sellErr(_w(0), t, 1_000 ether), P2pOnlyModule.PeerToPeerOnly.selector), "pool sell closed");
        _send(t, _w(0), carol, 1_000 ether); // wallet to wallet works
        vm.warp(vm.getBlockTimestamp() + 86400);
        _roundTrip(t, alice, _small(t));
        _routerSell(carol, t, 1_000 ether);
    }

    /// alliances: 2% holding cap, no treaties.
    function test_alliances() public {
        HookTokenV2 t = _launch(address(alliances), _alliancesCfg());
        assertTrue(_has(_curveBuyErr(bob, t, _target(t) / 4), AlliancesModule.CapExceeded.selector), "cap");
        _fillCapped(t, 15_000_000 ether, 200, 0, 0);
        _roundTrip(t, alice, _small(t));
        // a rival treaty after launch: HOOK holders are refused from max(rivalMin, 0.1% of HOOK's supply)
        // (the floor stops a dust send of the rival from barring a wallet)
        vm.prank(creator);
        alliances.proposeTreaty(address(t), HOOK_TOKEN, 2);
        deal(HOOK_TOKEN, carol, alliances.rivalMinOf(address(t), HOOK_TOKEN));
        assertTrue(_has(_buyErr(carol, t, _small(t)), AlliancesModule.RivalHolder.selector), "rival");
    }
}

// ==================================================================== holding / buy / sell caps

/// forge-config: default.isolate = true
contract NewHooksForkCapsTest is NewHooksForkBase {
    /// arcade: Lights Out, unlock at 60, 0.1% cap. Wallets play to unlock, then fill the curve.
    function test_arcade() public {
        HookTokenV2 t = _launch(address(arcade), abi.encode(ArcadeModule.Config(lightsOut, 60, 10, false, false)));
        assertEq(scores.gameOf(address(t)), lightsOut);
        // refusal: a locked wallet can't hold more than 0.1%
        assertTrue(_has(_curveBuyErr(bob, t, _target(t) / 20), ArcadeModule.CapExceeded.selector), "cap");
        for (uint256 i; i < 10; ++i) _unlock(_w(i), t);
        _unlock(alice, t);
        assertTrue(arcade.unlocked(address(t), _w(0)));
        _fill(t, 12, 10);
        _roundTrip(t, alice, _small(t));
        // a locked wallet can still buy under the cap in the pool
        _routerBuy(bob, t, _small(t) / 10);
    }

    function _unlock(address who, HookTokenV2 t) internal {
        vm.prank(who);
        bytes32 seed = scores.startRun(address(t));
        vm.roll(vm.getBlockNumber() + 1);
        uint256 presses = uint256(seed) & ((1 << 25) - 1);
        bytes memory inputs;
        uint256 board = LightsOutGame(lightsOut).init(seed);
        bool cancelled;
        {
            // init presses `presses` unless they cancel out (then the centre cell)
            uint256 b;
            for (uint256 c; c < 25; ++c) if (presses & (1 << c) != 0) b ^= _mask(c);
            cancelled = b == 0;
            assertEq(cancelled ? _mask(12) : b, board);
        }
        if (cancelled) {
            inputs = abi.encodePacked(uint8(12));
        } else {
            for (uint256 c; c < 25; ++c) if (presses & (1 << c) != 0) inputs = abi.encodePacked(inputs, uint8(c));
        }
        vm.prank(who);
        uint256 s = scores.submitRun(address(t), inputs);
        assertGe(s, 60, "score unlocks");
    }

    function _mask(uint256 c) internal pure returns (uint256 m) {
        uint256 r = c / 5;
        uint256 col = c % 5;
        m = 1 << c;
        if (r > 0) m |= 1 << (c - 5);
        if (r < 4) m |= 1 << (c + 5);
        if (col > 0) m |= 1 << (c - 1);
        if (col < 4) m |= 1 << (c + 1);
    }

    /// chapters: 1% cap, doubling every 100M tokens of volume, lifted at 16%.
    function test_chapters() public {
        HookTokenV2 t = _launch(address(chapters), _chaptersCfg());
        assertTrue(_has(_curveBuyErr(bob, t, _target(t) / 8), ChaptersModule.MaxWalletExceeded.selector), "cap");
        _fillCapped(t, 9_000_000 ether, 200, 0, 0);
        _roundTrip(t, alice, _small(t));
    }

    /// rising max wallet: 0.1% + 0.1% every 5 minutes.
    function test_risingMaxWallet() public {
        HookTokenV2 t = _launch(address(rmw), _rmwCfg());
        assertTrue(_has(_curveBuyErr(bob, t, _grossFor(t, 2_000_000 ether)), RisingMaxWalletModule.MaxWalletExceeded.selector), "cap");
        vm.warp(vm.getBlockTimestamp() + 3 hours); // cap 3.7%
        _fillCapped(t, 30_000_000 ether, 200, 0, 0);
        _roundTrip(t, alice, _small(t));
    }

    /// conviction cap: 0.1% per buy for a fresh wallet, +0.1% per day held, up to 2%.
    function test_convictionCap() public {
        HookTokenV2 t = _launch(address(conviction), _convictionCfg());
        assertTrue(_has(_curveBuyErr(bob, t, _grossFor(t, 2_000_000 ether)), ConvictionCapModule.BuyCapExceeded.selector), "fresh cap");
        for (uint256 i; i < 12; ++i) _curveBuy(_w(i), t, _grossFor(t, 500_000 ether));
        vm.warp(vm.getBlockTimestamp() + 20 days); // held 20 days: cap 2%
        (uint256 cap,,) = conviction.capOf(address(t), _w(0));
        assertEq(cap, SUPPLY * 200 / 10_000, "ceiling");
        _fillCapped(t, 18_000_000 ether, 12, 0, 0);
        _roundTrip(t, alice, _small(t) / 4);
    }

    /// resonance: per-buy cap on a damped oscillator (base 1%, floor 0.25%).
    function test_resonance() public {
        HookTokenV2 t = _launch(address(resonance), _resonanceCfg());
        assertTrue(_has(_curveBuyErr(bob, t, _target(t) / 4), ResonanceModule.BuyCapExceeded.selector), "cap");
        uint256 n = _fillByCap(t, address(resonance), 5);
        emit log_named_uint("resonance curve buys", n);
        _roundTrip(t, alice, _small(t));
    }

    /// coupled resonator: per-buy cap on two coupled oscillators (base 1%, floor 0.25%).
    function test_coupledResonator() public {
        HookTokenV2 t = _launch(address(coupled), abi.encode(CoupledResonatorModule.Config(100, 25, 60, 60, 1000, 20, 4000)));
        assertTrue(_has(_curveBuyErr(bob, t, _target(t) / 4), CoupledResonatorModule.BuyCapExceeded.selector), "cap");
        uint256 n = _fillByCap(t, address(coupled), 5);
        emit log_named_uint("coupled resonator curve buys", n);
        _roundTrip(t, alice, _small(t));
    }

    /// reactive pair: a first token, then a second linked to it (same creator).
    function test_reactivePair() public {
        HookTokenV2 a = _launch(address(reactive), _reactiveCfg(address(0)));
        HookTokenV2 b = _launch(address(reactive), _reactiveCfg(address(a)));
        assertEq(reactive.partnerOf(address(a)), address(b));
        assertEq(reactive.partnerOf(address(b)), address(a));
        // refusals: a third token can't link to a linked token; another creator can't link at all
        (uint32[] memory ids, bytes[] memory cfgs) = _one(address(reactive), _reactiveCfg(address(a)));
        vm.expectRevert();
        this.launchExt(creator, ids, cfgs);
        HookTokenV2 c = _launch(address(reactive), _reactiveCfg(address(0)));
        (ids, cfgs) = _one(address(reactive), _reactiveCfg(address(c)));
        vm.expectRevert();
        this.launchExt(bob, ids, cfgs);
        // buy cap
        assertTrue(_has(_curveBuyErr(bob, a, _target(a) / 4), ReactivePairModule.BuyCapExceeded.selector), "cap");
        uint256 capB0 = reactive.currentCap(address(b));
        _fillByCap(a, address(reactive), 5);
        assertGt(reactive.currentCap(address(b)), capB0, "buying A widened B's cap");
        _fillByCap(b, address(reactive), 5);
        _roundTrip(a, alice, _small(a));
        _roundTrip(b, alice, _small(b));
    }

    /// graduated sell caps: whales (>= 3%) sell at most 0.1% per transaction, small bags 1%, 1 day.
    function test_graduatedSellCap() public {
        HookTokenV2 t = _launch(address(gsc), abi.encode(GraduatedSellCapModule.Config(50, 100, 300, 10, 86400)));
        _curveBuy(bob, t, _target(t) / 10); // bob: a whale (~8% of supply)
        assertGe(t.balanceOf(bob), SUPPLY * 300 / 10_000);
        uint256 bal = t.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(); // curve sell over the whale cap
        PAD.sell(address(t), 2_000_000 ether, 0);
        _curveSell(bob, t, 900_000 ether); // under 0.1%
        _fill(t, 40, 40);
        assertTrue(_has(_sellErr(bob, t, 2_000_000 ether), GraduatedSellCapModule.SellCapExceeded.selector), "whale cap");
        _roundTrip(t, alice, _small(t));
        _routerSell(bob, t, 900_000 ether);
        // after the window the whale sells freely
        vm.warp(vm.getBlockTimestamp() + 86400);
        _routerSell(bob, t, bal / 2);
    }
}

// ==================================================================== early blocks, timing, physics

/// forge-config: default.isolate = true
contract NewHooksForkTimingTest is NewHooksForkBase {
    /// anti-bundle: 3 counted buys (>= 0.05%) per block, first 300 blocks of the curve and of the pool.
    function test_antiBundle() public {
        HookTokenV2 t = _launch(address(antiBundle), _antiBundleCfg());
        vm.roll(vm.getBlockNumber() + 1);
        uint256 b = _target(t) / 100;
        _curveBuy(_w(0), t, b);
        _curveBuy(_w(1), t, b);
        _curveBuy(_w(2), t, b);
        assertTrue(_has(_curveBuyErr(_w(3), t, b), AntiBundleModule.TooManyBuysThisBlock.selector), "4th buy");
        // fill with 3 buys per block
        uint256 chunk = _target(t) / 30 + 1;
        for (uint256 i; i < 120 && !PAD.getLaunch(address(t)).complete; ++i) {
            if (i % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            _curveBuy(_w(i % 40), t, chunk);
        }
        assertTrue(_graduated(t));
        vm.roll(vm.getBlockNumber() + 1);
        uint256 amt = _target(t) / 50;
        _routerBuy(alice, t, amt);
        _routerBuy(bob, t, amt);
        _routerBuy(carol, t, amt);
        assertTrue(_has(_buyErr(_w(5), t, amt), AntiBundleModule.TooManyBuysThisBlock.selector), "pool 4th buy");
        _routerSell(alice, t, t.balanceOf(alice) / 2); // sells never counted
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(_w(5), t, amt);
    }

    /// block zero: 3 curve blocks for the creator only.
    function test_blockZero() public {
        HookTokenV2 t = _launch(address(blockZero), abi.encode(BlockZeroModule.Config(3, 0)));
        assertTrue(_has(_curveBuyErr(alice, t, 1 ether), BlockZeroModule.CreatorOnly.selector), "creator only");
        _curveBuy(creator, t, 1 ether);
        vm.roll(vm.getBlockNumber() + 3);
        _fill(t, 40, 20);
        _roundTrip(t, alice, _small(t));
    }

    /// red light: 60 s slots, 60% green, at most 5 red in a row, sells open on red.
    function test_redLight() public {
        HookTokenV2 t = _launch(address(redLight), _redLightCfg());
        // find a red slot
        uint256 k = 1;
        bool green;
        uint256 startsAt;
        for (; k < 200; ++k) {
            (green, startsAt) = redLight.slotGreen(address(t), k);
            if (!green) break;
        }
        assertFalse(green, "a red slot");
        _curveBuy(_w(0), t, 1 ether);
        vm.warp(startsAt);
        assertFalse(redLight.isGreen(address(t)));
        assertTrue(_has(_curveBuyErr(alice, t, 1 ether), RedLightModule.RedLight.selector), "red: buy refused");
        _curveSell(_w(0), t, t.balanceOf(_w(0)) / 2); // sells open
        uint256 chunk = _target(t) / 40 + 1;
        for (uint256 i; i < 120 && !PAD.getLaunch(address(t)).complete; ++i) {
            if (!redLight.isGreen(address(t))) vm.warp(redLight.nextChange(address(t)));
            _curveBuy(_w(i % 40), t, chunk);
        }
        assertTrue(_graduated(t));
        if (!redLight.isGreen(address(t))) vm.warp(redLight.nextChange(address(t)));
        _roundTrip(t, alice, _small(t));
    }
}

// ==================================================================== sell locks, grudges

/// forge-config: default.isolate = true
contract NewHooksForkLocksTest is NewHooksForkBase {
    /// holder vesting: buys in the first day (>= 0.05%) vest: 1 day cliff, then 10% a day.
    function test_holderVesting() public {
        HookTokenV2 t = _launch(address(vesting), _vestingCfg());
        _fill(t, 40, 20);
        // refusal: curve tokens are locked
        uint256 bal = t.balanceOf(_w(0));
        assertEq(vesting.transferable(address(t), _w(0)), 0);
        assertTrue(_has(_sellErr(_w(0), t, bal / 10), HolderVestingModule.StillLocked.selector), "locked sell");
        assertTrue(_has(_sendErr(t, _w(0), bob, bal / 10), HolderVestingModule.StillLocked.selector), "locked send");
        // after the early window: router buys don't vest
        vm.warp(vm.getBlockTimestamp() + 86400 + 1);
        _roundTrip(t, alice, _small(t));
        // a day after the cliff 10% is free
        vm.warp(vm.getBlockTimestamp() + 86400);
        assertGe(vesting.transferable(address(t), _w(0)), bal / 10 - 1);
        _routerSell(_w(0), t, bal / 20);
    }

    /// lock & earn: 2% of every trade to lockers, min lock 1 day.
    function test_lockEarn() public {
        HookTokenV2 t = _launch(address(lockEarn), _lockEarnCfg());
        _fill(t, 40, 20);
        uint256 bal = t.balanceOf(_w(0));
        vm.prank(_w(0));
        lockEarn.lock(address(t), bal / 2, block.timestamp + 2 days);
        // refusal: can't go below the locked amount
        assertTrue(_has(_sellErr(_w(0), t, (bal * 3) / 4), LockEarnModule.LockedTokens.selector), "locked");
        _routerSell(_w(0), t, bal / 4);
        _roundTrip(t, alice, _small(t) * 5);
        (,, uint256 pending) = lockEarn.lockOf(address(t), _w(0));
        assertGt(pending, 0, "locker earned");
        uint256 b0 = _w(0).balance;
        vm.prank(_w(0));
        lockEarn.claim(address(t));
        assertGt(_w(0).balance, b0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _routerSell(_w(0), t, t.balanceOf(_w(0)) / 2); // unlocked
    }

    /// the grudge: selling >= 50% of the bag in one tx bans buys for 1 day (max 7).
    function test_grudge() public {
        HookTokenV2 t = _launch(address(grudge), abi.encode(GrudgeModule.Config(5000, 86400, 604800, 0, 0, 0)));
        _fill(t, 40, 20);
        uint256 got = _routerBuy(alice, t, _small(t));
        _routerSell(alice, t, got / 4); // 25% of the bag: no dump
        (, uint256 c0,) = grudge.grudgeOf(address(t), alice);
        assertEq(c0, 0);
        uint256 bal = t.balanceOf(_w(0));
        _routerSell(_w(0), t, (bal * 6) / 10); // a dump
        (, uint256 count, bool active) = grudge.grudgeOf(address(t), _w(0));
        assertEq(count, 1);
        assertTrue(active);
        assertTrue(_has(_buyErr(_w(0), t, _small(t)), GrudgeModule.BuyBanned.selector), "banned");
        vm.warp(vm.getBlockTimestamp() + 86400);
        _routerBuy(_w(0), t, _small(t));
    }
}

// ==================================================================== pots and treasuries

/// forge-config: default.isolate = true
contract NewHooksForkPotsTest is NewHooksForkBase {
    /// rising floor: 1% of every trade into a redeemable treasury.
    function test_risingFloor() public {
        HookTokenV2 t = _launch(address(risingFloor), _risingFloorCfg());
        _curveBuy(_w(0), t, 1 ether);
        vm.prank(_w(0));
        vm.expectRevert(); // refusal: redeem opens at graduation
        risingFloor.redeem(address(t), 1_000 ether, 0);
        _fill(t, 40, 20);
        _roundTrip(t, alice, _small(t));
        uint256 f0 = risingFloor.floorPrice(address(t));
        assertGt(f0, 0);
        uint256 b0 = _w(1).balance;
        vm.prank(_w(1));
        t.approve(address(risingFloor), 1_000_000 ether); // redeem pulls the tokens
        vm.prank(_w(1));
        uint256 out = risingFloor.redeem(address(t), 1_000_000 ether, 0);
        assertGt(out, 0);
        assertEq(_w(1).balance - b0, out);
        assertGe(risingFloor.floorPrice(address(t)), f0, "floor never falls");
    }

    /// quantum jackpot: 2% into a pot, hourly rounds, minBuy = $5 of AVAX, winner must hold 0.01%.
    function test_jackpot() public {
        uint256 minBuy = (5e18 * 1e18) / _usd();
        // refusal: a minBuy under $1 can't launch
        (uint32[] memory ids, bytes[] memory cfgs) =
            _one(address(jackpot), abi.encode(JackpotModule.Config(200, 3600, uint96(minBuy / 10), 1)));
        vm.expectRevert();
        this.launchExt(creator, ids, cfgs);
        HookTokenV2 t = _launch(address(jackpot), abi.encode(JackpotModule.Config(200, 3600, uint96(minBuy), 1)));
        _fill(t, 40, 20);
        _roundTrip(t, alice, _small(t));
        vm.warp(vm.getBlockTimestamp() + 3601);
        _routerBuy(bob, t, _small(t)); // first touch after the round: commits the draw
        vm.roll(vm.getBlockNumber() + 2);
        assertTrue(jackpot.canSettle(address(t)));
        (address winner, uint256 paid) = jackpot.settle(address(t));
        emit log_named_address("jackpot winner", winner);
        emit log_named_decimal_uint("jackpot paid (AVAX)", paid, 18);
        if (winner != address(0)) assertGt(HOOK.claimable(winner, NATIVE), 0);
    }

    /// underwater: 2% into a loss-refund pot; keeper rounds hourly.
    function test_underwater() public {
        HookTokenV2 t = _launch(address(underwater), abi.encode(UnderwaterModule.Config(200, 1, 3600, 2500, 2500)));
        _fill(t, 40, 20);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _routerBuy(alice, t, _target(t) / 20); // alice buys high
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        for (uint256 i; i < 10; ++i) _routerSell(_w(i), t, t.balanceOf(_w(i)) / 2); // the price falls
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _routerBuy(carol, t, _small(t) / 10); // updates the TWAP
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _routerSell(carol, t, t.balanceOf(carol) / 2);
        address[] memory ws = new address[](1);
        ws[0] = alice;
        vm.prank(bob);
        vm.expectRevert(UnderwaterModule.NotKeeper.selector);
        underwater.distribute(address(t), ws);
        uint256 c0 = HOOK.claimable(alice, NATIVE);
        vm.prank(keeper);
        (uint256 paid, uint256 count) = underwater.distribute(address(t), ws);
        emit log_named_decimal_uint("underwater paid alice (AVAX)", paid, 18);
        assertEq(count, 1, "alice underwater");
        assertGt(paid, 0);
        assertEq(HOOK.claimable(alice, NATIVE) - c0, paid);
        vm.prank(keeper);
        vm.expectRevert(); // TooSoon
        underwater.distribute(address(t), ws);
    }

    /// polarity: BULL on AVAX, then a BEAR pairing it.
    function test_polarity() public {
        HookTokenV2 bull = _launch(address(polarity), _polarityCfg(0, address(0)));
        // refusal: a BEAR by another creator can't pair it
        (uint32[] memory ids, bytes[] memory cfgs) = _one(address(polarity), _polarityCfg(1, address(bull)));
        vm.expectRevert(PolarityModule.BadPartner.selector);
        this.launchExt(bob, ids, cfgs);
        HookTokenV2 bear = _launch(address(polarity), _polarityCfg(1, address(bull)));
        (PolarityModule.Pair memory p,,) = polarity.pairOf(address(bull));
        assertTrue(p.paired);
        assertEq(p.bearToken, address(bear));
        // one BEAR per BULL
        vm.expectRevert(PolarityModule.BadPartner.selector);
        this.launchExt(creator, ids, cfgs);
        _fill(bull, 40, 20);
        _fill(bear, 40, 20);
        (uint256 potBull, uint256 potBear,) = polarity.previewPots(address(bull));
        assertGt(potBull, 0);
        assertGt(potBear, 0);
        // AVAX up 10%: BEAR's pot pays BULL's
        uint256 px = _usd();
        vm.mockCall(HOOK.quoteRegistry(), abi.encodeWithSelector(QuoteRegistry.usdPrice.selector, address(0)), abi.encode((px * 11) / 10));
        _roundTrip(bull, alice, _small(bull));
        _roundTrip(bear, alice, _small(bear));
        (uint256 potBull1, uint256 potBear1,) = polarity.previewPots(address(bull));
        emit log_named_decimal_uint("BULL pot", potBull1, 18);
        emit log_named_decimal_uint("BEAR pot", potBear1, 18);
        assertGt(potBull1, potBull);
        uint256 q = polarity.previewRedeem(address(bull), 1_000_000 ether);
        uint256 b0 = _w(0).balance;
        vm.prank(_w(0));
        bull.approve(address(polarity), 1_000_000 ether); // redeem pulls the tokens
        vm.prank(_w(0));
        uint256 out = polarity.redeem(address(bull), 1_000_000 ether, 0);
        assertEq(out, q);
        assertEq(_w(0).balance - b0, out);
    }
}

// ==================================================================== combos and conflict groups

/// forge-config: default.isolate = true
contract NewHooksForkComboTest is NewHooksForkBase {
    /// AntiBundle + RedLight(sellsOpen) + RisingFloor + LockEarn in one launch.
    function test_combo() public {
        uint32[] memory ids = new uint32[](4);
        bytes[] memory cfgs = new bytes[](4);
        (ids[0], cfgs[0]) = (idOf[address(antiBundle)], _antiBundleCfg());
        (ids[1], cfgs[1]) = (idOf[address(redLight)], _redLightCfg());
        (ids[2], cfgs[2]) = (idOf[address(risingFloor)], _risingFloorCfg());
        (ids[3], cfgs[3]) = (idOf[address(lockEarn)], _lockEarnCfg());
        HookTokenV2 t = _launchAs(creator, ids, cfgs);
        uint256 chunk = _target(t) / 30 + 1;
        for (uint256 i; i < 200 && !PAD.getLaunch(address(t)).complete; ++i) {
            if (i % 3 == 0) vm.roll(vm.getBlockNumber() + 1);
            if (!redLight.isGreen(address(t))) vm.warp(redLight.nextChange(address(t)));
            _curveBuy(_w(i % 40), t, chunk);
        }
        assertTrue(_graduated(t));
        uint256 bal = t.balanceOf(_w(0));
        vm.prank(_w(0));
        lockEarn.lock(address(t), bal / 2, block.timestamp + 2 days);
        vm.roll(vm.getBlockNumber() + 1);
        if (!redLight.isGreen(address(t))) vm.warp(redLight.nextChange(address(t)));
        uint256 got = _routerBuy(alice, t, _small(t) * 3);
        _routerSell(alice, t, got / 2);
        assertTrue(_has(_sellErr(_w(0), t, (bal * 3) / 4), LockEarnModule.LockedTokens.selector), "lock holds");
        (,, uint256 pending) = lockEarn.lockOf(address(t), _w(0));
        assertGt(pending, 0);
        assertGt(risingFloor.floorPrice(address(t)), 0);
        vm.prank(_w(1));
        t.approve(address(risingFloor), 1_000_000 ether);
        vm.prank(_w(1));
        assertGt(risingFloor.redeem(address(t), 1_000_000 ether, 0), 0);
    }

    function _pair(address a, bytes memory ca, address b, bytes memory cb) internal {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (idOf[a], idOf[b]);
        (cfgs[0], cfgs[1]) = (ca, cb);
        vm.expectRevert(abi.encodeWithSelector(AvaxHookV2.ModuleConflict.selector, idOf[b]));
        this.launchExt(creator, ids, cfgs);
    }

    function test_conflicts() public {
        address[] memory one = new address[](1);
        one[0] = alice;
        _pair(address(vesting), _vestingCfg(), address(lockEarn), _lockEarnCfg()); // sellLock
        _pair(address(resonance), _resonanceCfg(), address(conviction), _convictionCfg()); // buyCap
        _pair(address(chapters), _chaptersCfg(), address(rmw), _rmwCfg()); // holdingCap
        _pair(address(alliances), _alliancesCfg(), address(arcade), abi.encode(ArcadeModule.Config(lightsOut, 60, 10, false, false)));
        _pair(
            address(allowlist),
            abi.encode(AllowlistModule.Config(one, bytes32(0), 604800)),
            address(blocklist),
            abi.encode(BlocklistModule.Config(one))
        ); // receiverList
        _pair(address(dexOnly), abi.encode(DexOnlyModule.Config(0)), address(p2p), abi.encode(P2pOnlyModule.Config(86400))); // venue
        _pair(address(risingFloor), _risingFloorCfg(), address(risingFloor), _risingFloorCfg()); // same module twice
    }
}
