// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {StockGateway} from "../contracts/bridge/StockGateway.sol";
import {StockOrders} from "../contracts/stock/StockOrders.sol";

/// forge script script/DeployOrders.s.sol --rpc-url avalanche --broadcast
/// Env: ADMIN_PRIVATE_KEY (deployer; configures, then offers ownership to OWNER),
///      LAUNCHPAD, ROUTER, REGISTRY, GATEWAY,
///      SOLVER (optional: allowed to fill orders; more via setSolver; SOLVER_ADDRESS also accepted),
///      FEE_RECIPIENT (protocol fee receiver; defaults to PROTOCOL_RECIPIENT; required on mainnet,
///      falls back to the deployer elsewhere),
///      OWNER (multisig/timelock; calls acceptOwnership() afterwards; required on mainnet unless
///      ALLOW_EOA_OWNER=true).
contract DeployOrders is Script {
    uint256 constant AVALANCHE = 43114;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin = vm.addr(pk);
        address solver = vm.envOr("SOLVER", vm.envOr("SOLVER_ADDRESS", address(0)));
        address feeTo = vm.envOr("FEE_RECIPIENT", vm.envOr("PROTOCOL_RECIPIENT", address(0)));
        if (feeTo == address(0)) {
            require(block.chainid != AVALANCHE, "set FEE_RECIPIENT / PROTOCOL_RECIPIENT");
            feeTo = admin;
        }
        address owner = vm.envOr("OWNER", address(0));
        if (owner == address(0) && block.chainid == AVALANCHE) {
            require(vm.envOr("ALLOW_EOA_OWNER", false), "set OWNER (multisig/timelock) or ALLOW_EOA_OWNER=true");
        }
        HookLaunchpad pad = HookLaunchpad(payable(vm.envAddress("LAUNCHPAD")));

        vm.startBroadcast(pk);
        StockOrders orders = new StockOrders(
            pad,
            AvaxHookRouter(payable(vm.envAddress("ROUTER"))),
            QuoteRegistry(vm.envAddress("REGISTRY")),
            StockGateway(vm.envAddress("GATEWAY")),
            admin,
            feeTo
        );
        if (solver != address(0)) orders.setSolver(solver, true);
        // Allowlist StockOrders on the launchpad. Only possible while the admin still owns the
        // launchpad; otherwise the OWNER multisig must send setTrustedCaller(orders, true).
        if (pad.owner() == admin) pad.setTrustedCaller(address(orders), true);
        else console2.log("launchpad owner must call setTrustedCaller(orders, true)");
        if (owner != address(0)) orders.transferOwnership(owner);
        vm.stopBroadcast();

        console2.log("StockOrders", address(orders));
        console2.log("fee bps", orders.feeBps(), "to", feeTo);
        if (solver != address(0)) console2.log("solver", solver);
        if (owner != address(0)) {
            console2.log("ownership offered to", owner, "- it must call acceptOwnership()");
        } else if (block.chainid == AVALANCHE) {
            console2.log("WARNING: StockOrders stays owned by the hot deployer EOA", admin);
        }
    }
}
