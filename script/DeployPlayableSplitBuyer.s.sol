// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {PartnerFeeModule} from "../contracts/v2/modules/PartnerFeeModule.sol";
import {PlayableSplitBuyer} from "../contracts/v2/PlayableSplitBuyer.sol";

/// Deploys PlayableSplitBuyer for GOATsino's playable launches (USDC-quoted), owned by the Safe, which then
/// has to trust it: `hooks-v2-ops.mjs playable <impl> <mode>` (launchpad.setTrustedCaller).
///
///   forge script script/DeployPlayableSplitBuyer.s.sol --rpc-url avalanche --broadcast
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only); LAUNCHPAD / PARTNER_FEE / QUOTE / PARTNER / HOUSE /
/// FLOOR_TOKENS / OWNER override the defaults below.
contract DeployPlayableSplitBuyer is Script {
    address constant LIVE_PAD = 0x922A73Bd8aC4db8729aADE7a09288Da536058F02;
    address constant LIVE_PARTNER_FEE = 0xE1c6Dc3426035A7d51259303da9bbE76Aa836700;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant GOAT_HOUSE = 0x4E50EF6D688AEF8DF851A8F43d700b81113A8885;
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;

    function run() external returns (PlayableSplitBuyer b) {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address pad = vm.envOr("LAUNCHPAD", LIVE_PAD);
        address pf = vm.envOr("PARTNER_FEE", LIVE_PARTNER_FEE);
        address quote = vm.envOr("QUOTE", USDC);
        bytes32 partnerId = keccak256(bytes(vm.envOr("PARTNER", string("goatsino"))));
        address house = vm.envOr("HOUSE", GOAT_HOUSE);
        uint256 floorTokens = vm.envOr("FLOOR_TOKENS", uint256(50_000_000 ether));
        address owner = vm.envOr("OWNER", SAFE);

        // The partner has to be registered in the module already, or no launch of it could pay anyway.
        (address payout,, bool active) = PartnerFeeModule(pf).partners(partnerId);
        require(payout != address(0) && active, "partner not registered in PartnerFeeModule");

        vm.startBroadcast(pk);
        b = new PlayableSplitBuyer(
            HookLaunchpadV2(payable(pad)), PartnerFeeModule(pf), IERC20(quote), partnerId, house, floorTokens, owner
        );
        vm.stopBroadcast();
        console2.log("PlayableSplitBuyer", address(b));
        console2.log("  launchpad  ", pad);
        console2.log("  partnerFee ", pf);
        console2.log("  quote      ", quote);
        console2.log("  house      ", house);
        console2.log("  floor      ", floorTokens / 1e18);
        console2.log("  owner      ", owner);
        console2.log("next: hooks-v2-ops.mjs playable", address(b), "<mode>  (launchpad.setTrustedCaller)");
    }
}
