// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";

/// Mainnet-safe launch of the house coins, all paired with AVAX: "Avax Hook" (HOOK, the featured
/// coin) plus HookWhale, HookCat, HookDog, HookShark and Avaxvarium. Same names, logos and hook
/// configs as the local Seed, but launched by one explicit key, with no buyer wallets and no
/// fake buys. Optional dev-buy per coin via DEV_BUY_WEI (default 0).
///
///   DEPLOYER_KEY=0x… LAUNCHPAD=0x… [DEV_BUY_WEI=…] \
///     forge script script/LaunchHouseCoins.s.sol --rpc-url avalanche            # dry-run
///     forge script script/LaunchHouseCoins.s.sol --rpc-url avalanche --broadcast --slow
///
/// Then set NEXT_PUBLIC_FEATURED_TOKEN to the HOOK address it logs.
contract LaunchHouseCoins is Script {
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    struct Coin {
        string name;
        string symbol;
        string image;
        string description;
    }

    function run() external returns (address[] memory launched) {
        uint256 key = vm.envUint("DEPLOYER_KEY"); // no fallback: must be set explicitly
        address creator = vm.addr(key);
        _refuseAnvilKey(creator);

        HookLaunchpad pad = HookLaunchpad(payable(vm.envAddress("LAUNCHPAD")));
        require(address(pad).code.length != 0, "LAUNCHPAD has no code");
        uint256 devBuy = vm.envOr("DEV_BUY_WEI", uint256(0));
        uint256 fee = pad.creationFee();
        require(creator.balance >= 6 * (fee + devBuy), "deployer balance too low for 6 launches");

        Coin[6] memory coins = [
            Coin(
                "Avax Hook",
                "HOOK",
                "/coins/hookavax-coin-logo.png",
                "The AvaxHook house coin. Launched on its own launchpad, graduated into Uniswap v4 with locked liquidity."
            ),
            Coin("HookWhale", "HWHALE", "/coins/hookwhale.png", "Big fish, small fees. Every buy burns a little."),
            Coin("HookCat", "HCAT", "/coins/hookcat.png", "Nine lives, one hook. Every 25th buy takes the pot."),
            Coin("HookDog", "HDOG", "/coins/hookdog.png", "Good boy fetches the buyback."),
            Coin("HookShark", "HSHARK", "/coins/hookshark.png", "Circles the pool. Big trades pay the surge fee."),
            Coin("Avaxvarium", "VARIUM", "/coins/avaxvarium.png", "A whole aquarium on Avalanche.")
        ];

        launched = new address[](coins.length);
        vm.startBroadcast(key);
        for (uint256 i; i < coins.length; ++i) {
            HookLaunchpad.LaunchArgs memory a;
            a.name = coins[i].name;
            a.symbol = coins[i].symbol;
            a.meta = HookToken.Metadata(coins[i].description, coins[i].image, "", "", "");
            a.quote = address(0); // AVAX
            a.hook = i == 0 ? houseHooks() : coinHooks(i - 1);
            a.devBuy = devBuy;
            launched[i] = pad.launch{value: fee + devBuy}(a);
        }
        vm.stopBroadcast();

        for (uint256 i; i < coins.length; ++i) console2.log(coins[i].symbol, launched[i]);
        console2.log("NEXT_PUBLIC_FEATURED_TOKEN=", launched[0]);
    }

    /// @dev anvil's ten default accounts are public knowledge: never launch from one of them.
    function _refuseAnvilKey(address creator) internal pure {
        for (uint32 i; i < 10; ++i) {
            require(creator != vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i)), "DEPLOYER_KEY is an anvil default key");
        }
    }

    /// Avax Hook: dynamic fee, burn, LP rewards, Nth-buy pot, buyback, creator fee with referrals.
    /// Kept identical to Seed.s.sol `_houseHooks`.
    function houseHooks() public pure returns (AvaxHook.HookConfig memory h) {
        h.baseFeePips = 3_000;
        h.maxFeePips = 10_000;
        h.surgeSens = 2;
        h.burnBps = 100;
        h.lpBps = 50;
        h.potBps = 100;
        h.potEveryNBuys = 25;
        h.potMinBuy = 1 ether;
        h.creatorFeeBps = 50;
        h.referralBps = 25;
        h.buybackBps = 100;
        h.buybackMaxSpend = 5 ether;
    }

    /// Kept identical to Seed.s.sol `_hooks(i)`: 0 HookWhale, 1 HookCat, 2 HookDog, 3 HookShark, 4 Avaxvarium.
    function coinHooks(uint256 i) public pure returns (AvaxHook.HookConfig memory h) {
        h.baseFeePips = 3_000;
        h.maxFeePips = 3_000;
        h.creatorFeeBps = 50;
        if (i == 0) h.burnBps = 200; // HookWhale: auto burn
        if (i == 1) {
            h.potBps = 100; // HookCat: Nth-buy pot
            h.potEveryNBuys = 25;
            h.potMinBuy = 1 ether;
        }
        if (i == 2) {
            h.buybackBps = 200; // HookDog: buyback & burn
            h.buybackMaxSpend = 5 ether;
        }
        if (i == 3) {
            h.maxFeePips = 10_000; // HookShark: dynamic fee
            h.surgeSens = 3;
        }
        if (i == 4) h.lpBps = 50; // Avaxvarium: LP rewards
    }
}
