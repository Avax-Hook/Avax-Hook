// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StockZap, IV3SwapRouter, IStockEscrow, IWETH9} from "../contracts/bridge/StockZap.sol";

/// Deploys StockZap on Robinhood Chain (4663). Immutable and owner-less: nothing to configure or hand over.
///
///   forge script script/DeployStockZap.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), ESCROW (StockEscrow; default: the live one).
///      ROUTER / WETH override the Uniswap v3 SwapRouter02 / WETH9 (defaults: the official Robinhood
///      Chain deployment, developers.uniswap.org → v3 deployments → Robinhood Chain).
contract DeployStockZap is Script {
    uint256 constant ROBINHOOD = 4663;
    address constant LIVE_ESCROW = 0xa5D1615cd93D64F74B2eD39fB9c3D79216657613;
    address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external returns (StockZap zap) {
        require(block.chainid == ROBINHOOD, "StockZap lives on Robinhood Chain (4663)");
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address escrow = vm.envOr("ESCROW", LIVE_ESCROW);
        address router = vm.envOr("ROUTER", SWAP_ROUTER_02);
        address weth = vm.envOr("WETH", WETH9);
        require(escrow.code.length != 0 && router.code.length != 0 && weth.code.length != 0, "missing contract");

        vm.startBroadcast(pk);
        zap = new StockZap(IV3SwapRouter(router), IStockEscrow(escrow), IWETH9(weth));
        vm.stopBroadcast();

        console2.log("StockZap", address(zap));
        console2.log("  escrow", escrow);
        console2.log("  router", router);
        console2.log("  weth  ", weth);
    }
}
