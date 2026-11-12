// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {AvaxHookV2, IModuleSource} from "../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {HookTokenFactoryV2} from "../contracts/v2/HookTokenFactoryV2.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {AvaxHookRouterV2} from "../contracts/v2/AvaxHookRouterV2.sol";
import {HookLensV2} from "../contracts/v2/HookLensV2.sol";

/// One-time AvaxHook v2 core deployment (run through `script/hook-runbook.sh deploy-core`).
///   forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast
/// Env: ADMIN_PRIVATE_KEY (deployer; binds everything, then offers ownership to OWNER),
///      OWNER (the Safe; required on mainnet), PROTOCOL_RECIPIENT (required on mainnet),
///      QUOTE_REGISTRY (default: the live v1 QuoteRegistry), TRUSTED_CALLERS (optional, comma-separated
///      contracts allowed to buy for others / sell deposited tokens on the v2 curve, e.g. StockOrders).
/// The v2 hook takes the live QuoteRegistry as-is; modules are deployed and registered separately
/// (`hook-runbook.sh register <Name>`).
contract DeployV2 is Script {
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
        HookTokenFactoryV2 factory = new HookTokenFactoryV2(address(hook));
        HookLaunchpadV2 pad = new HookLaunchpadV2(POOL_MANAGER, hook, factory, QuoteRegistry(quotes), admin, treasury);
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        AvaxHookRouterV2 router = new AvaxHookRouterV2(POOL_MANAGER, pad);
        hook.bindRouter(address(router));
        HookLensV2 lens = new HookLensV2(pad);
        for (uint256 i; i < trusted.length; ++i) {
            pad.setTrustedCaller(trusted[i], true);
        }
        if (owner != address(0)) {
            registry.transferOwnership(owner); // Ownable2Step: the Safe accepts (hook-runbook.sh safe-core)
            pad.transferOwnership(owner);
        }
        vm.stopBroadcast();

        console2.log("V2 HookModuleRegistry", address(registry));
        console2.log("V2 AvaxHookV2", address(hook));
        console2.log("V2 HookTokenFactoryV2", address(factory));
        console2.log("V2 HookLaunchpadV2", address(pad));
        console2.log("V2 AvaxHookRouterV2", address(router));
        console2.log("V2 HookLensV2", address(lens));
        console2.log("V2 QuoteRegistry", quotes);
        if (owner != address(0)) console2.log("Ownership of registry + launchpad offered to", owner);
        else console2.log("WARNING: registry + launchpad stay owned by the deployer EOA", admin);
    }
}

/// Deploys one module by name (contracts/v2/modules/<Name>Module.sol), bound to the v2 hook.
///   forge script script/DeployV2.s.sol:DeployModule --sig "run(string)" KingOfTheHill --rpc-url <rpc> --broadcast
/// Env: ADMIN_PRIVATE_KEY, HOOK_V2.
contract DeployModule is Script {
    function run(string calldata name) external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envAddress("HOOK_V2");
        require(hook.code.length > 0, "no hook code at HOOK_V2");
        string memory artifact = string.concat(name, "Module.sol:", name, "Module");
        bytes memory init = abi.encodePacked(vm.getCode(artifact), abi.encode(hook));
        address m;
        vm.startBroadcast(pk);
        assembly ("memory-safe") {
            m := create(0, add(init, 0x20), mload(init))
        }
        vm.stopBroadcast();
        require(m != address(0) && m.code.length > 0, "module deploy failed");
        console2.log("V2 MODULE", name, m);
    }
}
