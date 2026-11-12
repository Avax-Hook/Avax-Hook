// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AvaxHookZap} from "../contracts/v2/AvaxHookZap.sol";

/// A replacement AvaxHookZap pinned to ParaSwap's Augustus v6.2, for a stack whose zap is pinned to v5 (the
/// API stopped quoting v5 routes). It copies the old zap: same router, same owner (the Safe), same neutral
/// modules. The old zap stays deployed: limit orders read `zappable` from it, and the two sets match.
///
///   OLD_ZAP=0x9C60…990d NEUTRAL=$(node script/zap-neutral.mjs 0x9C60…990d) \
///     forge script script/DeployZapV62.s.sol --rpc-url avalanche --broadcast
///
/// Live zaps: v2 0x9C608BAeE175F3faaB83D18a6a805379043e990d, v3 0xd6e66656eb8d23084aaf5d8962d5120e8b3ad3eb.
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), OLD_ZAP, NEUTRAL (comma-separated, from zap-neutral.mjs).
contract DeployZapV62 is Script {
    function run() external returns (AvaxHookZap zap) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        AvaxHookZap old = AvaxHookZap(payable(vm.envAddress("OLD_ZAP")));
        require(address(old).code.length != 0, "no code at OLD_ZAP");
        address[] memory neutral = vm.envAddress("NEUTRAL", ",");
        require(neutral.length != 0, "empty NEUTRAL");
        for (uint256 i; i < neutral.length; ++i) {
            require(old.neutral(neutral[i]), "a NEUTRAL module isn't neutral on OLD_ZAP");
        }

        vm.startBroadcast(pk);
        zap = new AvaxHookZap(old.router(), neutral, old.owner());
        vm.stopBroadcast();

        require(zap.AUGUSTUS() == 0x6A000F20005980200259B80c5102003040001068, "not pinned to Augustus v6.2");
        console2.log("AvaxHookZap (v6.2)", address(zap));
        console2.log("  replaces ", address(old));
        console2.log("  router   ", address(zap.router()));
        console2.log("  neutral  ", neutral.length);
        console2.log("  owner    ", zap.owner());
    }
}
