// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {QuoteRegistry} from "../../contracts/QuoteRegistry.sol";
import {AvaxHookV2, IModuleSource} from "../../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../../contracts/v2/HookModuleRegistry.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HookTokenFactoryV2} from "../../contracts/v2/HookTokenFactoryV2.sol";
import {AvaxHookRouterV2} from "../../contracts/v2/AvaxHookRouterV2.sol";
import {HookLensV2} from "../../contracts/v2/HookLensV2.sol";
import {KingOfTheHillModule} from "../../contracts/v2/modules/KingOfTheHillModule.sol";
import {MaxPerWalletModule} from "../../contracts/v2/modules/MaxPerWalletModule.sol";
import {DirectSwapper} from "./V2Mocks.sol";

/// v2 core deployed on an Avalanche mainnet fork, against the LIVE QuoteRegistry (read only).
abstract contract V2Base is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    QuoteRegistry constant LIVE_QUOTES = QuoteRegistry(0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1);
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    Currency constant NATIVE = Currency.wrap(address(0));
    uint256 constant FORK_BLOCK = 96_761_000;

    HookModuleRegistry modules;
    AvaxHookV2 hook;
    HookTokenFactoryV2 factory;
    HookLaunchpadV2 pad;
    AvaxHookRouterV2 router;
    HookLensV2 lens;
    KingOfTheHillModule koth;
    MaxPerWalletModule mpw;
    uint32 kothId;
    uint32 mpwId;
    DirectSwapper agg;

    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public virtual {
        uint256 blk = vm.envOr("V2_FORK_BLOCK", FORK_BLOCK);
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")), blk);
        modules = new HookModuleRegistry(address(this));
        (, bytes32 salt) = HookMiner.find(
            address(this),
            _requiredFlags(),
            type(AvaxHookV2).creationCode,
            abi.encode(address(PM), address(this), address(modules), address(LIVE_QUOTES))
        );
        hook = new AvaxHookV2{salt: salt}(PM, address(this), IModuleSource(address(modules)), address(LIVE_QUOTES));
        modules.bindHook(address(hook));
        factory = new HookTokenFactoryV2(address(hook));
        pad = new HookLaunchpadV2(PM, hook, factory, LIVE_QUOTES, address(this), treasury);
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        router = new AvaxHookRouterV2(PM, pad);
        hook.bindRouter(address(router));
        lens = new HookLensV2(pad);

        koth = new KingOfTheHillModule(address(hook));
        mpw = new MaxPerWalletModule(address(hook));
        kothId = modules.addModule(address(koth), '{"name":"King of the Hill"}');
        mpwId = modules.addModule(address(mpw), '{"name":"Max per wallet"}');
        agg = new DirectSwapper(PM);

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
        vm.deal(address(agg), 100_000 ether);
    }

    function _requiredFlags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    // ---------------------------------------------------------------- configs

    function _kothCfg(uint128 minBuy, uint16 beatBps, uint16 feeBps, uint32 decay, bool creatorOk) internal pure returns (bytes memory) {
        return abi.encode(KingOfTheHillModule.Config(minBuy, beatBps, feeBps, decay, creatorOk));
    }

    function _mpwCfg(uint16 maxBps, uint32 duration) internal pure returns (bytes memory) {
        return abi.encode(MaxPerWalletModule.Config(maxBps, duration, false));
    }

    function _mpwCfg(uint16 maxBps, uint32 duration, bool exemptCreator) internal pure returns (bytes memory) {
        return abi.encode(MaxPerWalletModule.Config(maxBps, duration, exemptCreator));
    }

    // ---------------------------------------------------------------- launch helpers

    function _launch(uint32[] memory ids, bytes[] memory cfgs, uint16 creatorFeeBps) internal returns (HookTokenV2 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "King";
        a.symbol = "KING";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: creatorFeeBps, baseFeePips: 3_000});
        a.moduleIds = ids;
        a.moduleConfigs = cfgs;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookTokenV2(pad.launch{value: fee}(a));
    }

    /// Fills the curve with buys of `target / 8` from fresh wallets (each stays under a 50% wallet cap).
    function _graduate(HookTokenV2 t) internal returns (PoolKey memory key) {
        uint256 chunk = uint256(pad.getLaunch(address(t)).target) / 8;
        for (uint256 i; i < 16 && !pad.getLaunch(address(t)).complete; ++i) {
            address w = address(uint160(0xB0B000 + i));
            vm.deal(w, chunk * 2);
            vm.prank(w);
            pad.buy{value: chunk}(address(t), 0);
        }
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        key = pad.poolKey(address(t));
    }

    function _kothMpw(uint128 minBuy, uint32 decay) internal returns (HookTokenV2 t, PoolKey memory key) {
        uint32[] memory ids = new uint32[](2);
        bytes[] memory cfgs = new bytes[](2);
        (ids[0], ids[1]) = (kothId, mpwId);
        cfgs[0] = _kothCfg(minBuy, 500, 50, decay, false);
        cfgs[1] = _mpwCfg(5_000, 0);
        t = _launch(ids, cfgs, 100);
        key = _graduate(t);
    }

    function _routerBuy(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        vm.prank(who);
        out = router.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "");
    }

    function _routerSell(address who, HookTokenV2 t, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(who);
        t.approve(address(router), amt);
        out = router.sell(address(t), amt, 0, block.timestamp, "");
        vm.stopPrank();
    }

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }
}
