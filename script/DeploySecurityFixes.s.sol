// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {PartnerFeeModule} from "../contracts/v2/modules/PartnerFeeModule.sol";
import {PlayableSplitBuyer} from "../contracts/v2/PlayableSplitBuyer.sol";
import {AlliancesModule} from "../contracts/v2/modules/AlliancesModule.sol";
import {AllowlistModule} from "../contracts/v2/modules/AllowlistModule.sol";
import {AntiBundleModule} from "../contracts/v2/modules/AntiBundleModule.sol";
import {AntiSnipeModule} from "../contracts/v2/modules/AntiSnipeModule.sol";
import {ConvictionCapModule} from "../contracts/v2/modules/ConvictionCapModule.sol";
import {CoupledResonatorModule} from "../contracts/v2/modules/CoupledResonatorModule.sol";
import {DynamicFeeModule} from "../contracts/v2/modules/DynamicFeeModule.sol";
import {GraduatedSellCapModule} from "../contracts/v2/modules/GraduatedSellCapModule.sol";
import {HolderDividendsModule} from "../contracts/v2/modules/HolderDividendsModule.sol";
import {HolderGatedModule} from "../contracts/v2/modules/HolderGatedModule.sol";
import {MomentumModule} from "../contracts/v2/modules/MomentumModule.sol";
import {PlagueModule} from "../contracts/v2/modules/PlagueModule.sol";

interface IHookView {
    function launchpad() external view returns (address);
}

/// Security fixes of 2026-11-10 (docs/security-2026-11.md): redeploys the fixed modules and the fixed
/// PlayableSplitBuyer for the live v3 hook. The deployer only pays gas; nothing here is owned by it.
/// The Safe then runs `hooks-v2-ops.mjs security-fixes <mode>` (V2_STATE=script/v3-state.json), which adds the
/// new modules, deprecates the old ids (pools already on them keep running), mirrors the Zap neutral flags,
/// and moves the launchpad's trust from the old buyer to the new one.
///
///   forge script script/DeploySecurityFixes.s.sol --rpc-url $AVAX_RPC_URL --broadcast --slow
///
/// Env: ADMIN_PRIVATE_KEY; HOOK / PARTNER_FEE / HOUSE / FLOOR_TOKENS / OWNER override the v3 defaults.
contract DeploySecurityFixes is Script {
    address constant V3_HOOK = 0xfD0753147E21C3F61e38aE27d6634B8C38CB6AcC;
    address constant V3_PARTNER_FEE = 0xFc338A096089786505ADb15f68e74BB28a8BDcF7;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant GOAT_HOUSE = 0x40a38bf9CCf14d8728229fBD60413C2AE0CbD49a;
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envOr("HOOK", V3_HOOK);
        address pad = IHookView(hook).launchpad();
        address pf = vm.envOr("PARTNER_FEE", V3_PARTNER_FEE);
        address house = vm.envOr("HOUSE", GOAT_HOUSE);
        uint256 floorTokens = vm.envOr("FLOOR_TOKENS", uint256(50_000_000 ether));
        address owner = vm.envOr("OWNER", SAFE);
        bytes32 partnerId = keccak256("goatsino");
        (address payout,, bool active) = PartnerFeeModule(pf).partners(partnerId);
        require(payout != address(0) && active, "goatsino not registered in PartnerFeeModule");

        vm.startBroadcast(pk);
        _log("Alliances", address(new AlliancesModule(hook)));
        _log("Allowlist", address(new AllowlistModule(hook)));
        _log("AntiBundle", address(new AntiBundleModule(hook)));
        _log("AntiSnipe", address(new AntiSnipeModule(hook)));
        _log("ConvictionCap", address(new ConvictionCapModule(hook)));
        _log("CoupledResonator", address(new CoupledResonatorModule(hook)));
        _log("DynamicFee", address(new DynamicFeeModule(hook)));
        _log("GraduatedSellCap", address(new GraduatedSellCapModule(hook)));
        _log("HolderDividends", address(new HolderDividendsModule(hook)));
        _log("HolderGated", address(new HolderGatedModule(hook)));
        _log("Momentum", address(new MomentumModule(hook)));
        _log("Plague", address(new PlagueModule(hook)));
        PlayableSplitBuyer b = new PlayableSplitBuyer(
            HookLaunchpadV2(payable(pad)), PartnerFeeModule(pf), IERC20(USDC), partnerId, house, floorTokens, owner
        );
        vm.stopBroadcast();
        console2.log("FIX PlayableSplitBuyer", address(b));
        console2.log("  launchpad", pad, "owner", owner);
    }

    function _log(string memory name, address impl) internal pure {
        console2.log(string.concat("FIX module:", name), impl);
    }
}
