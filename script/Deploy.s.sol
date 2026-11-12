// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {HookLens} from "../contracts/HookLens.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";

/// forge script script/Deploy.s.sol --rpc-url avalanche --broadcast
/// Env: ADMIN_PRIVATE_KEY (deployer; configures, then offers ownership to OWNER),
///      PROTOCOL_RECIPIENT (fee treasury; required on mainnet, defaults to the admin elsewhere),
///      OWNER (multisig/timelock; calls acceptOwnership() on QuoteRegistry and HookLaunchpad
///      afterwards; required on mainnet unless ALLOW_EOA_OWNER=true),
///      KEEPER_ADDRESS (optional hook buyback keeper),
///      START_FDV_USD / END_FDV_USD (whole dollars, default 2,500 → 50,000)
contract Deploy is Script {
    uint256 constant AVALANCHE = 43114;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // Circle, 6 decimals
    address constant AVAX_USD = 0x0A77230d17318075983913bC2145DB16C7366156; // Chainlink
    address constant USDC_USD = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9; // Chainlink
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7; // Tether, 6 decimals
    address constant USDT_USD = 0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a; // Chainlink

    function run() external returns (HookLaunchpad pad) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin = vm.addr(pk);
        address treasury = vm.envOr("PROTOCOL_RECIPIENT", address(0));
        if (block.chainid == AVALANCHE) require(treasury != address(0), "set PROTOCOL_RECIPIENT on mainnet");
        if (treasury == address(0)) treasury = admin;
        address owner = _owner();
        uint128 startFdv = uint128(vm.envOr("START_FDV_USD", uint256(2_500)) * 1e8);
        uint128 endFdv = uint128(vm.envOr("END_FDV_USD", uint256(50_000)) * 1e8);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AvaxHook).creationCode, abi.encode(address(POOL_MANAGER), admin));

        vm.startBroadcast(pk);
        AvaxHook hook = new AvaxHook{salt: salt}(POOL_MANAGER, admin);
        require(address(hook) == expected, "hook address mismatch");
        HookTokenFactory factory = new HookTokenFactory();
        QuoteRegistry registry = new QuoteRegistry(admin);
        registry.setQuote(address(0), true, AVAX_USD); // native AVAX
        registry.setQuote(USDC, true, USDC_USD);
        registry.setQuote(USDT, true, USDT_USD);
        // Tokenized stocks: run `pnpm stocks:deploy` afterwards (no Chainlink equity feeds on C-Chain).
        if (startFdv != 2_500e8 || endFdv != 50_000e8) registry.setFdv(startFdv, endFdv);
        pad = new HookLaunchpad(POOL_MANAGER, hook, factory, registry, admin, treasury);
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        AvaxHookRouter router = new AvaxHookRouter(POOL_MANAGER, pad);
        hook.bindRouter(address(router));
        HookLens lens = new HookLens(pad);

        // Buyback keeper (deployer-only on the hook; set before the ownership hand-over below).
        address keeper = vm.envOr("KEEPER_ADDRESS", address(0));
        if (keeper != address(0)) hook.setKeeper(keeper);
        // StockOrders is allowlisted on the launchpad from DeployOrders.s.sol (it is deployed later).

        // Ownable2Step: OWNER must call acceptOwnership() on each to take over.
        if (owner != address(0)) {
            registry.transferOwnership(owner);
            pad.transferOwnership(owner);
            // AvaxHook is not Ownable: its keeper setter stays with the immutable `deployer` (this admin key).
        }
        vm.stopBroadcast();

        console2.log("AvaxHook        ", address(hook));
        console2.log("HookTokenFactory", address(factory));
        console2.log("HookLaunchpad   ", address(pad));
        console2.log("AvaxHookRouter  ", address(router));
        console2.log("HookLens        ", address(lens));
        console2.log("QuoteRegistry   ", address(registry));
        if (owner != address(0)) {
            console2.log("Ownership of QuoteRegistry + HookLaunchpad offered to", owner);
            console2.log("  -> OWNER must call acceptOwnership() on both");
        } else {
            console2.log("WARNING: QuoteRegistry + HookLaunchpad stay owned by the deployer EOA", admin);
        }
        console2.log("Set these as NEXT_PUBLIC_LAUNCHPAD / NEXT_PUBLIC_HOOK / NEXT_PUBLIC_ROUTER / NEXT_PUBLIC_LENS in .env.local");
    }

    /// @dev Production hands admin to a multisig behind a timelock; a hot EOA owner needs an explicit
    ///      opt-in on mainnet (ALLOW_EOA_OWNER=true, as in DeployBridge.s.sol).
    function _owner() internal view returns (address owner) {
        owner = vm.envOr("OWNER", address(0));
        if (owner == address(0) && block.chainid == AVALANCHE) {
            require(vm.envOr("ALLOW_EOA_OWNER", false), "set OWNER (multisig/timelock) or ALLOW_EOA_OWNER=true");
            console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            console2.log("WARNING: no OWNER set - the hot deployer EOA keeps admin on mainnet");
            console2.log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        }
    }
}
