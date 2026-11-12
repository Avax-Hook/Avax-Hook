// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ArcadeScores} from "../contracts/v2/arcade/ArcadeScores.sol";
import {LightsOutGame} from "../contracts/v2/arcade/LightsOutGame.sol";
import {Game2048} from "../contracts/v2/arcade/Game2048.sol";
import {AlliancesModule} from "../contracts/v2/modules/AlliancesModule.sol";
import {AllowlistModule} from "../contracts/v2/modules/AllowlistModule.sol";
import {AntiBundleModule} from "../contracts/v2/modules/AntiBundleModule.sol";
import {ArcadeModule} from "../contracts/v2/modules/ArcadeModule.sol";
import {BlockZeroModule} from "../contracts/v2/modules/BlockZeroModule.sol";
import {BlocklistModule} from "../contracts/v2/modules/BlocklistModule.sol";
import {ChaptersModule} from "../contracts/v2/modules/ChaptersModule.sol";
import {ConvictionCapModule} from "../contracts/v2/modules/ConvictionCapModule.sol";
import {CoupledResonatorModule} from "../contracts/v2/modules/CoupledResonatorModule.sol";
import {DexOnlyModule} from "../contracts/v2/modules/DexOnlyModule.sol";
import {GraduatedSellCapModule} from "../contracts/v2/modules/GraduatedSellCapModule.sol";
import {GrudgeModule} from "../contracts/v2/modules/GrudgeModule.sol";
import {HolderGatedModule} from "../contracts/v2/modules/HolderGatedModule.sol";
import {HolderVestingModule} from "../contracts/v2/modules/HolderVestingModule.sol";
import {JackpotModule} from "../contracts/v2/modules/JackpotModule.sol";
import {LockEarnModule} from "../contracts/v2/modules/LockEarnModule.sol";
import {P2pOnlyModule} from "../contracts/v2/modules/P2pOnlyModule.sol";
import {PlagueModule} from "../contracts/v2/modules/PlagueModule.sol";
import {PolarityModule} from "../contracts/v2/modules/PolarityModule.sol";
import {ReactivePairModule} from "../contracts/v2/modules/ReactivePairModule.sol";
import {RedLightModule} from "../contracts/v2/modules/RedLightModule.sol";
import {ResonanceModule} from "../contracts/v2/modules/ResonanceModule.sol";
import {RisingFloorModule} from "../contracts/v2/modules/RisingFloorModule.sol";
import {RisingMaxWalletModule} from "../contracts/v2/modules/RisingMaxWalletModule.sol";
import {UnderwaterModule} from "../contracts/v2/modules/UnderwaterModule.sol";

/// Deploys the 25 new hook modules for the live AvaxHookV2, plus ArcadeScores (owned by the Safe) and the
/// two Arcade games. Prints "V2 MODULE <Name> <addr>" / "V2 ARCADE <key> <addr>" lines that
/// script/new-hooks-runbook.sh writes into v2-state; then `hooks-v2-ops.mjs hooks-batch` registers them.
///
///   forge script script/DeployNewHooks.s.sol --rpc-url avalanche --broadcast --slow
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas only), HOOK / OWNER overrides.
contract DeployNewHooks is Script {
    address constant LIVE_HOOK = 0x179278C7ECD2cFbc003D76985Ba05f11DDc36ACc;
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    // Polarity price assets: the QuoteRegistry quotes backed by Chainlink aggregators (AVAX, USDC, USDt).
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envOr("HOOK", LIVE_HOOK);
        address owner = vm.envOr("OWNER", SAFE);
        require(hook.code.length > 0, "no hook code");
        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (address(0), USDC, USDT);

        vm.startBroadcast(pk);
        ArcadeScores scores = new ArcadeScores(owner);
        address lightsOut = address(new LightsOutGame());
        address g2048 = address(new Game2048());
        _m("Alliances", address(new AlliancesModule(hook)));
        _m("Allowlist", address(new AllowlistModule(hook)));
        _m("AntiBundle", address(new AntiBundleModule(hook)));
        _m("Arcade", address(new ArcadeModule(hook, scores)));
        _m("BlockZero", address(new BlockZeroModule(hook)));
        _m("Blocklist", address(new BlocklistModule(hook)));
        _m("Chapters", address(new ChaptersModule(hook)));
        _m("ConvictionCap", address(new ConvictionCapModule(hook)));
        _m("CoupledResonator", address(new CoupledResonatorModule(hook)));
        _m("DexOnly", address(new DexOnlyModule(hook)));
        _m("GraduatedSellCap", address(new GraduatedSellCapModule(hook)));
        _m("Grudge", address(new GrudgeModule(hook)));
        _m("HolderGated", address(new HolderGatedModule(hook)));
        _m("HolderVesting", address(new HolderVestingModule(hook)));
        _m("Jackpot", address(new JackpotModule(hook)));
        _m("LockEarn", address(new LockEarnModule(hook)));
        _m("P2pOnly", address(new P2pOnlyModule(hook)));
        _m("Plague", address(new PlagueModule(hook)));
        _m("Polarity", address(new PolarityModule(hook, assets)));
        _m("ReactivePair", address(new ReactivePairModule(hook)));
        _m("RedLight", address(new RedLightModule(hook)));
        _m("Resonance", address(new ResonanceModule(hook)));
        _m("RisingFloor", address(new RisingFloorModule(hook)));
        _m("RisingMaxWallet", address(new RisingMaxWalletModule(hook)));
        _m("Underwater", address(new UnderwaterModule(hook, owner)));
        vm.stopBroadcast();

        console2.log("V2 ARCADE ArcadeScores", address(scores));
        console2.log("V2 ARCADE arcade:game:LightsOut", lightsOut);
        console2.log("V2 ARCADE arcade:game:2048", g2048);
    }

    function _m(string memory name, address m) internal pure {
        console2.log("V2 MODULE", name, m);
    }
}
