// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AvaxHookV2} from "../contracts/v2/AvaxHookV2.sol";
import {HookLaunchpadV2} from "../contracts/v2/HookLaunchpadV2.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {HookTokenV2} from "../contracts/v2/HookTokenV2.sol";
import {IHookModule} from "../contracts/v2/interfaces/IHookModule.sol";

/// Launches the v2 house coins on HookLaunchpadV2, all paired with AVAX: HookWhale, HookShark, HookDog,
/// HookCat and Avaxvarium ("Avax Hook" / HOOK is not part of this set). Names, symbols and logos as the v1
/// house coins (script/LaunchHouseCoins.s.sol); v1 hook blocks are replaced by registry modules.
///
/// Core per coin (as v1's house coins): creator fee 0.5%, base pool fee 0.3%. No curve guard (v1's house
/// coins had none). Optional dev buy per coin via DEV_BUY_WEI (default 0).
///
/// Module ids are not hard-coded: each module's impl comes from script/v2-state.json (`module:<Name>`),
/// its id from the registry (`idOf`). Before broadcasting, every module is checked to be active, unchanged
/// (codehash) and conflict-free, and every config passes the module's own `validateConfig`.
/// Coins already launched by the deployer (same symbol) are skipped, so a re-run doesn't double-launch.
///
///   set -a; . ./.env; . ./.env.services; set +a
///   DEPLOYER_KEY=$ADMIN_PRIVATE_KEY CONFIRM_HOUSE_COINS_V2=yes \
///     forge script script/LaunchHouseCoinsV2.s.sol --rpc-url avalanche                    # simulate
///   DEPLOYER_KEY=$ADMIN_PRIVATE_KEY CONFIRM_HOUSE_COINS_V2=yes \
///     forge script script/LaunchHouseCoinsV2.s.sol --rpc-url avalanche --broadcast --slow  # launch
///
/// Writes script/house-coins-v2.json.
contract LaunchHouseCoinsV2 is Script {
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
    string constant STATE = "script/v2-state.json";
    string constant OUT = "script/house-coins-v2.json";

    uint16 constant CREATOR_FEE_BPS = 50; // 0.5%, as v1 house coins
    uint24 constant BASE_FEE_PIPS = 3_000; // 0.3%, as v1 house coins

    struct Coin {
        string name;
        string symbol;
        string image;
        string description;
        string modules; // human-readable, for the log / json
        uint32[] ids;
        bytes[] configs;
        address quote; // address(0) = AVAX
        string website;
        string twitter;
    }

    HookModuleRegistry registry;
    string state;

    address constant KET = 0xFFFF003a6BAD9b743d658048742935fFFE2b6ED7; // Avalanche quote coin, 18 decimals

    function run() external returns (address[] memory launched) {
        require(
            keccak256(bytes(vm.envOr("CONFIRM_HOUSE_COINS_V2", string("")))) == keccak256("yes"),
            "set CONFIRM_HOUSE_COINS_V2=yes"
        );
        uint256 key = vm.envUint("DEPLOYER_KEY"); // no fallback: must be set explicitly
        address creator = vm.addr(key);
        _refuseAnvilKey(creator);

        state = vm.readFile(STATE);
        HookLaunchpadV2 pad = HookLaunchpadV2(payable(vm.parseJsonAddress(state, ".HookLaunchpadV2")));
        registry = HookModuleRegistry(vm.parseJsonAddress(state, ".HookModuleRegistry"));
        AvaxHookV2 hook = AvaxHookV2(payable(vm.parseJsonAddress(state, ".AvaxHookV2")));
        require(address(pad).code.length != 0, "launchpad has no code");
        require(address(pad.hook()) == address(hook), "launchpad/hook mismatch");
        require(address(hook.moduleRegistry()) == address(registry), "hook/registry mismatch");
        require(!pad.launchesPaused(), "launches paused");

        AvaxHookV2.CoreConfig memory core = AvaxHookV2.CoreConfig(CREATOR_FEE_BPS, BASE_FEE_PIPS);
        hook.validateCore(core);

        Coin[] memory coins = _coins();
        for (uint256 i; i < coins.length; ++i) _check(coins[i]);

        uint256 devBuy = vm.envOr("DEV_BUY_WEI", uint256(0));
        uint256 fee = pad.creationFee();
        launched = new address[](coins.length);
        uint256 todo;
        string memory only = vm.envOr("ONLY", string("")); // e.g. ONLY=HCAT launches just that coin
        bool[] memory skip = new bool[](coins.length);
        for (uint256 i; i < coins.length; ++i) {
            launched[i] = _existing(pad, creator, coins[i].symbol, coins[i].quote);
            skip[i] = launched[i] != address(0)
                || (bytes(only).length != 0 && keccak256(bytes(only)) != keccak256(bytes(coins[i].symbol)))
                || (keccak256(bytes(coins[i].symbol)) == keccak256("HOOK") && keccak256(bytes(only)) != keccak256("HOOK"));
            if (!skip[i]) ++todo;
        }
        require(creator.balance >= todo * (fee + devBuy), "deployer balance too low");
        console2.log("deployer", creator);
        console2.log("creationFee (wei)", fee);
        console2.log("launches to send", todo);

        vm.startBroadcast(key);
        for (uint256 i; i < coins.length; ++i) {
            if (skip[i]) {
                if (launched[i] != address(0)) console2.log("already launched, skipping", coins[i].symbol, launched[i]);
                continue;
            }
            HookLaunchpadV2.LaunchArgs memory a;
            a.name = coins[i].name;
            a.symbol = coins[i].symbol;
            a.meta = HookTokenV2.Metadata(coins[i].description, coins[i].image, coins[i].website, coins[i].twitter, "");
            a.quote = coins[i].quote; // address(0) = AVAX
            a.core = core;
            // a.guard: off (v1 house coins launched without a curve guard)
            a.moduleIds = coins[i].ids;
            a.moduleConfigs = coins[i].configs;
            a.devBuy = devBuy;
            // devBuy is AVAX-only (non-AVAX quotes would need an approval; house coins launch without one)
            launched[i] = pad.launch{value: coins[i].quote == address(0) ? fee + devBuy : fee}(a);
        }
        vm.stopBroadcast();

        string memory root = "root";
        string memory list = "coins";
        string memory coinsJson;
        for (uint256 i; i < coins.length; ++i) {
            console2.log(coins[i].symbol, launched[i], coins[i].modules);
            string memory k = coins[i].symbol;
            vm.serializeString(k, "name", coins[i].name);
            vm.serializeString(k, "image", coins[i].image);
            vm.serializeString(k, "modules", coins[i].modules);
            vm.serializeUint(k, "moduleIds", _toUints(coins[i].ids));
            string memory entry = vm.serializeAddress(k, "token", launched[i]);
            coinsJson = vm.serializeString(list, k, entry);
        }
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "launchpad", address(pad));
        vm.serializeAddress(root, "creator", creator);
        vm.serializeUint(root, "creatorFeeBps", CREATOR_FEE_BPS);
        vm.serializeUint(root, "baseFeePips", BASE_FEE_PIPS);
        string memory out = vm.serializeString(root, "coins", coinsJson);
        vm.writeJson(out, OUT);
    }

    // ---------------------------------------------------------------- coins

    function _coins() internal view returns (Coin[] memory c) {
        c = new Coin[](6);

        // HookWhale: King of the Hill (min crown 1 AVAX, beat 5%, King 0.5%, bar halves every 6 h, creator
        // can't be King) + pool-open anti-snipe (150 blocks, 5 AVAX per block, 2.5% tax).
        c[0].name = "HookWhale";
        c[0].symbol = "HWHALE";
        c[0].image = "/coins/hookwhale.png";
        c[0].description = "Big fish, small fees. The biggest buy wears the crown.";
        c[0].modules = "KingOfTheHill + AntiSnipe";
        c[0].ids = new uint32[](2);
        c[0].configs = new bytes[](2);
        (c[0].ids[0], c[0].configs[0]) =
            (_id("KingOfTheHill"), abi.encode(uint128(1 ether), uint16(500), uint16(50), uint32(6 hours), false));
        (c[0].ids[1], c[0].configs[1]) = (_id("AntiSnipe"), abi.encode(uint32(150), uint96(5 ether), uint16(250)));

        // HookShark: anti-snipe (as HookWhale) + MEV shield (300 blocks, 5 gwei tip cap) + whale guard
        // (1,800 blocks, 10 AVAX per transaction).
        c[1].name = "HookShark";
        c[1].symbol = "HSHARK";
        c[1].image = "/coins/hookshark.png";
        c[1].description = "Circles the pool. Snipers, front-runners and whales get bitten early.";
        c[1].modules = "AntiSnipe + MevShield + WhaleGuard";
        c[1].ids = new uint32[](3);
        c[1].configs = new bytes[](3);
        (c[1].ids[0], c[1].configs[0]) = (_id("AntiSnipe"), abi.encode(uint32(150), uint96(5 ether), uint16(250)));
        (c[1].ids[1], c[1].configs[1]) = (_id("MevShield"), abi.encode(uint32(300), uint64(5 gwei)));
        (c[1].ids[2], c[1].configs[2]) = (_id("WhaleGuard"), abi.encode(uint32(1_800), uint96(10 ether)));

        // HookDog: referral (1% module fee, 0.5% of it to the referrer) + auto burn 0.5%.
        c[2].name = "HookDog";
        c[2].symbol = "HDOG";
        c[2].image = "/coins/hookdog.png";
        c[2].description = "Good boy fetches friends. Every buy burns a little.";
        c[2].modules = "Referral + AutoBurn";
        c[2].ids = new uint32[](2);
        c[2].configs = new bytes[](2);
        (c[2].ids[0], c[2].configs[0]) = (_id("Referral"), abi.encode(uint16(100), uint16(50)));
        (c[2].ids[1], c[2].configs[1]) = (_id("AutoBurn"), abi.encode(uint16(50)));

        // HookCat (KET-paired): momentum (defaults) + last-buyer pot (1%, 30 min clock, 3,500 KET ≈ 0.5 AVAX to lead).
        c[3].name = "HookCat";
        c[3].symbol = "HCAT";
        c[3].image = "/coins/hookcat.png";
        c[3].description = "Nine lives, one hook. The last buyer takes the pot.";
        c[3].modules = "Momentum + LastBuyerPot";
        c[3].ids = new uint32[](2);
        c[3].configs = new bytes[](2);
        (c[3].ids[0], c[3].configs[0]) =
            (_id("Momentum"), abi.encode(uint16(100), uint16(25), uint32(120), uint16(100), uint16(4_000)));
        (c[3].ids[1], c[3].configs[1]) = (_id("LastBuyerPot"), abi.encode(uint16(100), uint32(30 minutes), uint96(3_500 ether)));
        c[3].quote = KET;

        // Avaxvarium: Nth-buy pot (1%, every 50th buy of >= 0.5 AVAX) + breathing cap (defaults).
        c[4].name = "Avaxvarium";
        c[4].symbol = "VARIUM";
        c[4].image = "/coins/avaxvarium.png";
        c[4].description = "A whole aquarium on Avalanche. Every 50th buy takes the pot.";
        c[4].modules = "NthBuyPot + BreathingCap";
        c[4].ids = new uint32[](2);
        c[4].configs = new bytes[](2);
        (c[4].ids[0], c[4].configs[0]) = (_id("NthBuyPot"), abi.encode(uint16(100), uint32(50), uint96(0.5 ether)));
        (c[4].ids[1], c[4].configs[1]) =
            (_id("BreathingCap"), abi.encode(uint16(100), uint16(6_000), uint16(10), uint32(300)));

        // Avax Hook: the official protocol token (launched only with ONLY=HOOK). Auto-burn + anti-snipe.
        c[5].name = "Avax Hook";
        c[5].symbol = "HOOK";
        c[5].image = "/coins/hookavax-coin-logo.png";
        c[5].description =
            "The official token of AvaxHook, the hook launchpad on Avalanche. Half of the protocol fees from every launch buy HOOK for the treasury, and every HOOK trade burns a little supply. Fair launch: no presale, no team allocation, one curve for everyone.";
        c[5].modules = "AutoBurn + AntiSnipe";
        c[5].website = "https://avaxhook.fun";
        c[5].twitter = "https://x.com/AvaxHookFun";
        c[5].ids = new uint32[](2);
        c[5].configs = new bytes[](2);
        (c[5].ids[0], c[5].configs[0]) = (_id("AutoBurn"), abi.encode(uint16(50)));
        (c[5].ids[1], c[5].configs[1]) = (_id("AntiSnipe"), abi.encode(uint32(150), uint96(5 ether), uint16(250)));
    }

    // ---------------------------------------------------------------- checks

    /// @dev Registry id of `module:<name>` in v2-state.json (reverts if the impl isn't registered).
    function _id(string memory name) internal view returns (uint32 id) {
        address impl = vm.parseJsonAddress(state, string.concat(".['module:", name, "']"));
        id = registry.idOf(impl);
        require(id != 0, string.concat("module not registered: ", name));
    }

    /// @dev Every module active, unchanged and conflict-free, every config accepted by its module.
    function _check(Coin memory c) internal view {
        uint32 seen;
        for (uint256 j; j < c.ids.length; ++j) {
            (address impl,, uint32 groups) = registry.forLaunch(c.ids[j]); // reverts unless active
            require(!registry.codehashChanged(c.ids[j]), "module codehash changed");
            require(groups & seen == 0, string.concat(c.symbol, ": module conflict"));
            for (uint256 k; k < j; ++k) require(c.ids[k] != c.ids[j], "duplicate module");
            seen |= groups;
            IHookModule(impl).validateConfig(c.configs[j]);
        }
    }

    /// @dev A token with this symbol AND quote the deployer already launched here (or address(0)).
    function _existing(HookLaunchpadV2 pad, address creator, string memory symbol, address quote)
        internal
        view
        returns (address)
    {
        address[] memory mine = pad.launchesByCreator(creator);
        for (uint256 i; i < mine.length; ++i) {
            if (keccak256(bytes(HookTokenV2(mine[i]).symbol())) != keccak256(bytes(symbol))) continue;
            if (pad.getLaunch(mine[i]).quote == quote) return mine[i];
        }
        return address(0);
    }

    /// @dev anvil's ten default accounts are public knowledge: never launch from one of them.
    function _refuseAnvilKey(address creator) internal pure {
        for (uint32 i; i < 10; ++i) {
            require(creator != vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i)), "DEPLOYER_KEY is an anvil default key");
        }
    }

    function _toUints(uint32[] memory a) internal pure returns (uint256[] memory r) {
        r = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) r[i] = a[i];
    }
}
