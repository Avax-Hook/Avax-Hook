// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AlliancesModule} from "../contracts/v2/modules/AlliancesModule.sol";
import {AllowlistModule} from "../contracts/v2/modules/AllowlistModule.sol";
import {BlocklistModule} from "../contracts/v2/modules/BlocklistModule.sol";
import {ChaptersModule} from "../contracts/v2/modules/ChaptersModule.sol";
import {ConvictionCapModule} from "../contracts/v2/modules/ConvictionCapModule.sol";
import {GraduatedSellCapModule} from "../contracts/v2/modules/GraduatedSellCapModule.sol";
import {GrudgeModule} from "../contracts/v2/modules/GrudgeModule.sol";
import {HolderGatedModule} from "../contracts/v2/modules/HolderGatedModule.sol";
import {HolderVestingModule} from "../contracts/v2/modules/HolderVestingModule.sol";
import {MaxPerWalletModule} from "../contracts/v2/modules/MaxPerWalletModule.sol";
import {PlagueModule} from "../contracts/v2/modules/PlagueModule.sol";
import {RisingMaxWalletModule} from "../contracts/v2/modules/RisingMaxWalletModule.sol";

/// Claims-bypass fix of 2026-11-12 (docs/security-2026-11.md, "ERC-6909 claims bypass"): redeploys the transfer-rule
/// modules that now refuse non-router pool swaps while their rule is active (RouterOnlyGuard). The deployer only
/// pays gas; the modules have no owner. Then:
///
///   forge script script/DeployClaimsFix.s.sol --rpc-url $AVAX_RPC_URL --broadcast --slow | tee cache/claims-fix.log
///   node script/record-security-fixes.mjs cache/claims-fix.log          (module:<Name> = new, retired-claims:module:<Name> = old)
///   V2_STATE=script/v3-state.json node script/hooks-v2-ops.mjs claims-fix <mode>          (v3: add + deprecate + zap flags)
///   FIX_DEPRECATE_ONLY=1 node script/hooks-v2-ops.mjs claims-fix <mode>                   (v2: deprecate only)
///
/// Env: ADMIN_PRIVATE_KEY; HOOK overrides the v3 hook.
contract DeployClaimsFix is Script {
    address constant V3_HOOK = 0xfD0753147E21C3F61e38aE27d6634B8C38CB6AcC;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envOr("HOOK", V3_HOOK);
        vm.startBroadcast(pk);
        _log("Alliances", address(new AlliancesModule(hook)));
        _log("Allowlist", address(new AllowlistModule(hook)));
        _log("Blocklist", address(new BlocklistModule(hook)));
        _log("Chapters", address(new ChaptersModule(hook)));
        _log("ConvictionCap", address(new ConvictionCapModule(hook)));
        _log("GraduatedSellCap", address(new GraduatedSellCapModule(hook)));
        _log("Grudge", address(new GrudgeModule(hook)));
        _log("HolderGated", address(new HolderGatedModule(hook)));
        _log("HolderVesting", address(new HolderVestingModule(hook)));
        _log("MaxPerWallet", address(new MaxPerWalletModule(hook)));
        _log("Plague", address(new PlagueModule(hook)));
        _log("RisingMaxWallet", address(new RisingMaxWalletModule(hook)));
        vm.stopBroadcast();
    }

    function _log(string memory name, address impl) internal pure {
        console2.log(string.concat("CLAIMSFIX module:", name), impl);
    }
}
