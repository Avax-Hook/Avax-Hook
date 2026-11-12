// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {AvaxHookV2, IModuleSource} from "../contracts/v2/AvaxHookV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {PoolCoordinatorV1, IPositionManagerLite} from "../contracts/v2/pools/PoolCoordinatorV1.sol";
import {PoolRouterV1} from "../contracts/v2/pools/PoolRouterV1.sol";
import {AvaxHookPoolsV1} from "../contracts/v2/pools/AvaxHookPoolsV1.sol";

/// Deployment of the existing-token profile: AvaxHookPoolsV1 (AvaxHookV2 plus the true full-fill check,
/// mined address with the same flags as the launch hook) with its own module registry, bound to
/// PoolCoordinatorV1 as its "launchpad" and to PoolRouterV1 as its trusted router. The coordinator is
/// deployed paused (checked at the end); the Safe reopens it with `hooks-v2-ops.mjs pools-pause false`.
///   forge script script/DeployPools.s.sol --rpc-url <rpc> --broadcast
/// Env: ADMIN_PRIVATE_KEY (deployer; binds everything, then offers ownership to OWNER),
///      OWNER (the Safe; required on mainnet), PROTOCOL_RECIPIENT (required on mainnet),
///      OPEN_FEE (wei, default 0.5 AVAX), QUOTES (comma-separated ERC-20 quotes to allow besides AVAX,
///      e.g. USDC, USDt, HOOK), QUOTE_REGISTRY (default: the live one),
///      POOLS_STATE (default script/pools-state.json; fork runs use cache/pools-state.fork.json),
///      POOLS_REDEPLOY=1 to deploy a new profile although the state file exists: the old file is then kept
///      as POOLS_RETIRED (default script/pools-state.retired-v1.json, never overwritten).
/// State files are only written by a broadcasting run (a dry run prints the addresses only).
/// Modules are deployed against the new hook afterwards with script/DeployPoolsModules.s.sol and
/// registered in the NEW registry by the Safe (node script/hooks-v2-ops.mjs pools <mode>). Only modules without ON_TRANSFER and without the
/// 1B-supply market-cap math belong in this profile, and no AntiSnipe (see HOOKR-FEATURES-PLAN.md).
contract DeployPools is Script {
    uint256 constant AVALANCHE = 43114;
    IPoolManager constant POOL_MANAGER = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    IPositionManagerLite constant POSITION_MANAGER = IPositionManagerLite(0xB74b1F14d2754AcfcbBe1a221023a5cf50Ab8ACD);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
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
        uint96 openFee = uint96(vm.envOr("OPEN_FEE", uint256(0.5 ether)));
        address quoteRegistry = vm.envOr("QUOTE_REGISTRY", LIVE_QUOTE_REGISTRY);
        address[] memory quotes = vm.envOr("QUOTES", ",", new address[](0));
        string memory stateFile = vm.envOr("POOLS_STATE", string("script/pools-state.json"));
        string memory retiredFile = vm.envOr("POOLS_RETIRED", string("script/pools-state.retired-v1.json"));
        bool retire = vm.exists(stateFile);
        if (retire) {
            require(
                vm.envOr("POOLS_REDEPLOY", uint256(0)) == 1,
                "pools profile already deployed (see POOLS_STATE); set POOLS_REDEPLOY=1 for a new one"
            );
            require(!vm.exists(retiredFile), "POOLS_RETIRED already exists; pick another file");
        }
        bool writes = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        require(address(POSITION_MANAGER).code.length > 0 && address(PERMIT2).code.length > 0, "no v4 periphery");

        address predictedRegistry = vm.computeCreateAddress(admin, vm.getNonce(admin));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(AvaxHookPoolsV1).creationCode,
            abi.encode(address(POOL_MANAGER), admin, predictedRegistry, quoteRegistry)
        );

        vm.startBroadcast(pk);
        HookModuleRegistry registry = new HookModuleRegistry(admin);
        require(address(registry) == predictedRegistry, "registry address mismatch");
        AvaxHookV2 hook =
            new AvaxHookPoolsV1{salt: salt}(POOL_MANAGER, admin, IModuleSource(address(registry)), quoteRegistry);
        require(address(hook) == expected, "hook address mismatch");
        registry.bindHook(address(hook));
        PoolCoordinatorV1 coord =
            new PoolCoordinatorV1(POOL_MANAGER, hook, POSITION_MANAGER, PERMIT2, admin, treasury, openFee);
        hook.bindLaunchpad(address(coord));
        PoolRouterV1 router = new PoolRouterV1(POOL_MANAGER, address(hook));
        hook.bindRouter(address(router));
        for (uint256 i; i < quotes.length; ++i) {
            coord.setQuote(quotes[i], true);
        }
        if (owner != address(0)) {
            registry.transferOwnership(owner); // Ownable2Step: the Safe accepts
            coord.transferOwnership(owner);
        }
        vm.stopBroadcast();
        // Audit I-5: nobody can open a pool before the Safe has wired up modules and quotes.
        require(coord.paused(), "coordinator must be deployed paused");
        require(hook.launchpad() == address(coord) && hook.router() == address(router), "hook bindings");

        string memory k = "pools";
        vm.serializeString(k, "hookContract", "AvaxHookPoolsV1");
        vm.serializeAddress(k, "HookModuleRegistry", address(registry));
        vm.serializeAddress(k, "AvaxHookV2", address(hook));
        vm.serializeAddress(k, "PoolCoordinatorV1", address(coord));
        string memory out = vm.serializeAddress(k, "PoolRouterV1", address(router));
        if (writes) {
            if (retire) {
                vm.writeFile(retiredFile, vm.readFile(stateFile));
                console2.log("previous state kept in", retiredFile);
            }
            vm.writeJson(out, stateFile);
        } else {
            console2.log("dry run: state files untouched");
        }

        console2.log("POOLS HookModuleRegistry", address(registry));
        console2.log("POOLS AvaxHookV2", address(hook));
        console2.log("POOLS PoolCoordinatorV1", address(coord));
        console2.log("POOLS PoolRouterV1", address(router));
        if (owner != address(0)) console2.log("Ownership of registry + coordinator offered to", owner);
        else console2.log("WARNING: registry + coordinator stay owned by the deployer EOA", admin);
    }
}
