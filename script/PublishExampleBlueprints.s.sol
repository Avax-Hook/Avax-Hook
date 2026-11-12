// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BlueprintRegistryV1} from "../contracts/v2/blueprints/BlueprintRegistryV1.sol";
import {MevShieldModule} from "../contracts/v2/modules/MevShieldModule.sol";
import {SellTaxDecayModule} from "../contracts/v2/modules/SellTaxDecayModule.sol";
import {DynamicFeeModule} from "../contracts/v2/modules/DynamicFeeModule.sol";
import {AutoBurnModule} from "../contracts/v2/modules/AutoBurnModule.sol";
import {HolderDividendsModule} from "../contracts/v2/modules/HolderDividendsModule.sol";
import {LpRewardsModule} from "../contracts/v2/modules/LpRewardsModule.sol";

/// The three official example blueprints (token launches, no royalty), published from the admin wallet so
/// the marketplace shows how blueprints work. Module ids are the live v2 registry's.
///   forge script script/PublishExampleBlueprints.s.sol --rpc-url <rpc> --broadcast
/// Env: ADMIN_PRIVATE_KEY, BLUEPRINTS (the BlueprintRegistryV1 address).
library ExampleBlueprints {
    // live v2 module ids (HookModuleRegistry 0xA84E…2286)
    uint32 internal constant AUTO_BURN = 2;
    uint32 internal constant DYNAMIC_FEE = 8;
    uint32 internal constant LP_REWARDS = 13;
    uint32 internal constant MEV_SHIELD = 17;
    uint32 internal constant SELL_TAX_DECAY = 22;
    uint32 internal constant HOLDER_DIVIDENDS = 28;

    string internal constant URI = "https://avaxhook.fun/docs/marketplace";

    struct Example {
        string name;
        bytes spec;
    }

    function all() internal pure returns (Example[3] memory e) {
        // 1. Anti-bot opening: MEV tips refused for ~5 min, a 5% sell tax that fades to 0 over 3,600 blocks,
        //    and a fee that rises on big trades (up to 1%).
        {
            uint32[] memory ids = new uint32[](3);
            bytes[] memory cfgs = new bytes[](3);
            (ids[0], ids[1], ids[2]) = (MEV_SHIELD, SELL_TAX_DECAY, DYNAMIC_FEE);
            cfgs[0] = abi.encode(MevShieldModule.Config(300, 5 gwei));
            cfgs[1] = abi.encode(SellTaxDecayModule.Config(3_600, 50_000));
            cfgs[2] = abi.encode(DynamicFeeModule.Config(10_000, 2));
            e[0] = Example("Fair Launch Shield", abi.encode(ids, cfgs, uint16(50), uint24(3_000)));
        }
        // 2. Deflationary holder token: 1% of every buy's tokens burned, 2% of every trade shared with holders.
        {
            uint32[] memory ids = new uint32[](2);
            bytes[] memory cfgs = new bytes[](2);
            (ids[0], ids[1]) = (AUTO_BURN, HOLDER_DIVIDENDS);
            cfgs[0] = abi.encode(AutoBurnModule.Config(100));
            cfgs[1] = abi.encode(HolderDividendsModule.Config(200));
            e[1] = Example("Deflationary Holder", abi.encode(ids, cfgs, uint16(50), uint24(3_000)));
        }
        // 3. Liquidity flywheel: 1% of every pool buy donated to in-range LPs, 0.5% of buy output burned,
        //    a 1% pool fee to LPs and no creator fee.
        {
            uint32[] memory ids = new uint32[](2);
            bytes[] memory cfgs = new bytes[](2);
            (ids[0], ids[1]) = (LP_REWARDS, AUTO_BURN);
            cfgs[0] = abi.encode(LpRewardsModule.Config(100));
            cfgs[1] = abi.encode(AutoBurnModule.Config(50));
            e[2] = Example("LP Flywheel", abi.encode(ids, cfgs, uint16(0), uint24(10_000)));
        }
    }
}

contract PublishExampleBlueprints is Script {
    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        BlueprintRegistryV1 registry = BlueprintRegistryV1(vm.envAddress("BLUEPRINTS"));
        require(address(registry).code.length > 0, "no registry code at BLUEPRINTS");
        ExampleBlueprints.Example[3] memory ex = ExampleBlueprints.all();
        vm.startBroadcast(pk);
        for (uint256 i; i < 3; ++i) {
            uint32 id = registry.publish(ex[i].name, ExampleBlueprints.URI, 0, ex[i].spec, 0, 0);
            console2.log("blueprint", id, ex[i].name);
        }
        vm.stopBroadcast();
    }
}
