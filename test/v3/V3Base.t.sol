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
import {HookTokenFactoryV2} from "../../contracts/v2/HookTokenFactoryV2.sol";
import {AvaxHookRouterV2} from "../../contracts/v2/AvaxHookRouterV2.sol";
import {HookLensV2} from "../../contracts/v2/HookLensV2.sol";
import {HookTokenV3} from "../../contracts/v3/HookTokenV3.sol";
import {HookTokenFactoryV3} from "../../contracts/v3/HookTokenFactoryV3.sol";

/// The v3 stack on an Avalanche mainnet fork, against the LIVE QuoteRegistry (read only).
///
/// v3 is the v2 core with one contract swapped: HookTokenFactoryV3 mints HookTokenV3s, which have no
/// curve-phase transfer lock. Every other piece — hook, launchpad, router, lens, modules — is the same
/// code as the live v2 deployment, deployed again as a second instance (as "Pool any token" already is),
/// because each is bound for good to the one before it: the launchpad's `tokenFactory` is immutable, the
/// hook's `bindLaunchpad` and the factory's `bindLaunchpad` are one-shot, and every module's `hook` is
/// immutable. The factory's `create` keeps the v2 selector, so the launchpad code runs unchanged.
abstract contract V3Base is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    QuoteRegistry constant LIVE_QUOTES = QuoteRegistry(0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    Currency constant NATIVE = Currency.wrap(address(0));
    uint256 constant FORK_BLOCK = 96_761_000;

    HookModuleRegistry modules;
    AvaxHookV2 hook;
    HookTokenFactoryV3 factory;
    HookLaunchpadV2 pad;
    AvaxHookRouterV2 router;
    HookLensV2 lens;

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
        factory = new HookTokenFactoryV3(address(hook));
        // The launchpad takes the factory by its v2 type; `create` has the same selector on both.
        pad = new HookLaunchpadV2(PM, hook, HookTokenFactoryV2(address(factory)), LIVE_QUOTES, address(this), treasury);
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        router = new AvaxHookRouterV2(PM, pad);
        hook.bindRouter(address(router));
        lens = new HookLensV2(pad);

        _registerModules();

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    /// Modules the test needs, deployed against this hook and approved in this registry.
    function _registerModules() internal virtual {}

    function _requiredFlags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    // ---------------------------------------------------------------- launch helpers

    function _launch(uint32[] memory ids, bytes[] memory cfgs) internal returns (HookTokenV3 t) {
        HookLaunchpadV2.LaunchArgs memory a;
        a.name = "Free Mover";
        a.symbol = "MOVE";
        a.core = AvaxHookV2.CoreConfig({creatorFeeBps: 100, baseFeePips: 3_000});
        a.moduleIds = ids;
        a.moduleConfigs = cfgs;
        uint256 fee = pad.creationFee();
        vm.prank(creator);
        t = HookTokenV3(pad.launch{value: fee}(a));
    }

    function _launch() internal returns (HookTokenV3 t) {
        return _launch(new uint32[](0), new bytes[](0));
    }

    function _buy(address who, HookTokenV3 t, uint256 amount) internal returns (uint256 got) {
        uint256 before = t.balanceOf(who);
        vm.prank(who);
        pad.buy{value: amount}(address(t), 0);
        got = t.balanceOf(who) - before;
    }

    /// Fills the curve with buys from fresh wallets until it graduates.
    function _graduate(HookTokenV3 t) internal returns (PoolKey memory key) {
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

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }
}
