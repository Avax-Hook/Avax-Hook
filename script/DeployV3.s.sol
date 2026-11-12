// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {AvaxHookV2, IModuleSource} from "../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {HookTokenFactoryV2} from "../contracts/v2/HookTokenFactoryV2.sol";
import {AvaxHookRouterV2} from "../contracts/v2/AvaxHookRouterV2.sol";
import {HookLensV2} from "../contracts/v2/HookLensV2.sol";
import {HookTokenFactoryV3} from "../contracts/v3/HookTokenFactoryV3.sol";

/// AvaxHook v3 core: the v2 stack with HookTokenFactoryV3 in place of the v2 factory, so its launches
/// mint HookTokenV3s — tokens a holder can send, burn or pool while the curve is still running.
///
/// Everything else is the v2 code, deployed a second time (as the "Pool any token" profile already is),
/// because each piece is bound for good to the one before it: the launchpad's `tokenFactory` is
/// immutable, the hook's and the factory's `bindLaunchpad` are one-shot, and every module's `hook` is
/// immutable. The v3 factory keeps the v2 `create` selector, so the launchpad code needs no change: it
/// takes this factory by the v2 type. v1 and v2 launches keep running untouched.
///
///   forge script script/DeployV3.s.sol --rpc-url avalanche --broadcast
///
/// Env: ADMIN_PRIVATE_KEY (deployer; binds everything, then offers ownership to OWNER),
///      OWNER (the Safe; required on mainnet), PROTOCOL_RECIPIENT (required on mainnet),
///      QUOTE_REGISTRY (default: the live QuoteRegistry, shared with v1/v2), TRUSTED_CALLERS (optional,
///      comma-separated contracts allowed to buy for others / sell deposited tokens on the v3 curve).
///
/// Next: `DeployV3Modules.s.sol` (the 55 modules, same ids as v2), then `DeployV3Periphery.s.sol`
/// (Zap + limit orders), then the Safe hand-over. Modules read `hook.launchpad()` in their constructors,
/// so they must be deployed after this script, never before.
contract DeployV3 is Script {
    uint256 constant AVALANCHE = 43114;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant LIVE_QUOTE_REGISTRY = 0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin = vm.addr(pk);
        address owner = vm.envOr("OWNER", address(0));
        address treasury = vm.envOr("PROTOCOL_RECIPIENT", address(0));
        if (block.chainid == AVALANCHE) {
            require(owner != address(0), "set OWNER (Safe) on mainnet");
            require(treasury != address(0), "set PROTOCOL_RECIPIENT on mainnet");
        }
        if (treasury == address(0)) treasury = admin;
        address quotes = vm.envOr("QUOTE_REGISTRY", LIVE_QUOTE_REGISTRY);
        require(quotes.code.length > 0, "no QuoteRegistry code");
        address[] memory trusted = vm.envOr("TRUSTED_CALLERS", ",", new address[](0));

        // The registry address is the deployer's next CREATE address; the hook's constructor needs it.
        address predictedRegistry = vm.computeCreateAddress(admin, vm.getNonce(admin));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(AvaxHookV2).creationCode,
            abi.encode(address(POOL_MANAGER), admin, predictedRegistry, quotes)
        );

        vm.startBroadcast(pk);
        HookModuleRegistry registry = new HookModuleRegistry(admin);
        require(address(registry) == predictedRegistry, "registry address mismatch");
        AvaxHookV2 hook = new AvaxHookV2{salt: salt}(POOL_MANAGER, admin, IModuleSource(address(registry)), quotes);
        require(address(hook) == expected, "hook address mismatch");
        registry.bindHook(address(hook));
        HookTokenFactoryV3 factory = new HookTokenFactoryV3(address(hook));
        // The launchpad takes the factory by its v2 type; `create` has the same selector on both.
        HookLaunchpadV2 pad = new HookLaunchpadV2(
            POOL_MANAGER, hook, HookTokenFactoryV2(address(factory)), QuoteRegistry(quotes), admin, treasury
        );
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        AvaxHookRouterV2 router = new AvaxHookRouterV2(POOL_MANAGER, pad);
        hook.bindRouter(address(router));
        HookLensV2 lens = new HookLensV2(pad);
        for (uint256 i; i < trusted.length; ++i) {
            pad.setTrustedCaller(trusted[i], true);
        }
        if (owner != address(0)) {
            registry.transferOwnership(owner); // Ownable2Step: the admin keeps the keys until the Safe accepts,
            pad.transferOwnership(owner); // which is what registers the modules in the next script
        }
        vm.stopBroadcast();

        console2.log("V3 HookModuleRegistry", address(registry));
        console2.log("V3 AvaxHookV2", address(hook));
        console2.log("V3 HookTokenFactoryV3", address(factory));
        console2.log("V3 HookLaunchpadV2", address(pad));
        console2.log("V3 AvaxHookRouterV2", address(router));
        console2.log("V3 HookLensV2", address(lens));
        console2.log("V3 QuoteRegistry", quotes);
        console2.log("next: HOOK_V3=%s REGISTRY_V3=%s", address(hook), address(registry));
        console2.log("      forge script script/DeployV3Modules.s.sol --rpc-url avalanche --broadcast --slow");
        if (owner != address(0)) console2.log("Ownership of registry + launchpad offered to", owner);
        else console2.log("WARNING: registry + launchpad stay owned by the deployer EOA", admin);
    }
}
