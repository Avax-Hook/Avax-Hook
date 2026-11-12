// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";

/// Launches the house coins through the launchpad, all paired with AVAX:
///   Avax Hook (from the deployer) and the placeholder coins HookWhale, HookCat, HookDog,
///   HookShark and Avaxvarium, at different stages of their curves. Nothing is mocked: every coin
///   is a real launchpad launch, bought on its curve, and the graduated ones trade on Uniswap v4.
///
/// LAUNCHPAD=0x… ROUTER=0x… DEPLOYER_KEY=0x… forge script script/Seed.s.sol --rpc-url <rpc> --broadcast --slow
/// Locally the buyers are anvil's funded accounts; DEPLOYER_KEY defaults to anvil #0.
/// LOCAL ONLY: it signs with anvil's public keys and makes fake buys. Mainnet house coins are
/// launched with script/LaunchHouseCoins.s.sol instead.
contract Seed is Script {
    uint256[4] buyers = [
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d,
        0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a,
        0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6,
        0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 // anvil #9 (not the relayer)
    ];

    struct Coin {
        string name;
        string symbol;
        string image;
        string description;
        uint16 progressBps; // how far to fill the curve (10_000 = graduate)
    }

    HookLaunchpad pad;
    AvaxHookRouter router;

    function run() external {
        _requireLocal();
        pad = HookLaunchpad(payable(vm.envAddress("LAUNCHPAD")));
        router = AvaxHookRouter(payable(vm.envAddress("ROUTER")));
        uint256 deployer = vm.envOr("DEPLOYER_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

        // The house coin, launched by the deployer wallet.
        _launch(
            deployer,
            Coin(
                "Avax Hook",
                "HOOK",
                "/coins/hookavax-coin-logo.png",
                "The AvaxHook house coin. Launched on its own launchpad, graduated into Uniswap v4 with locked liquidity.",
                10_000
            ),
            _houseHooks()
        );

        Coin[5] memory coins = [
            Coin("HookWhale", "HWHALE", "/coins/hookwhale.png", "Big fish, small fees. Every buy burns a little.", 10_000),
            Coin("HookCat", "HCAT", "/coins/hookcat.png", "Nine lives, one hook. Every 25th buy takes the pot.", 6_000),
            Coin("HookDog", "HDOG", "/coins/hookdog.png", "Good boy fetches the buyback.", 3_500),
            Coin("HookShark", "HSHARK", "/coins/hookshark.png", "Circles the pool. Big trades pay the surge fee.", 1_500),
            Coin("Avaxvarium", "VARIUM", "/coins/avaxvarium.png", "A whole aquarium on Avalanche.", 500)
        ];
        for (uint256 i; i < coins.length; ++i) _launch(buyers[i % 4], coins[i], _hooks(i));
    }

    /// @dev Refuses to run against a real network. The local demo forks Avalanche with chain id 43114,
    ///      so on that id the node must also identify as anvil (a public RPC rejects `anvil_nodeInfo`).
    function _requireLocal() internal {
        if (block.chainid != 43114) return;
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory info) {
            require(info.length != 0, "Seed is local-only (anvil fork)");
        } catch {
            revert("Seed is local-only: refusing to run on Avalanche mainnet");
        }
    }

    function _launch(uint256 creatorKey, Coin memory c, AvaxHook.HookConfig memory h) internal {
        HookLaunchpad.LaunchArgs memory a;
        a.name = c.name;
        a.symbol = c.symbol;
        a.meta = HookToken.Metadata(c.description, c.image, "", "", "");
        a.hook = h;
        uint256 fee = pad.creationFee();
        vm.broadcast(creatorKey);
        address t = pad.launch{value: fee}(a);

        // Fill the curve to the coin's stage with buys from several wallets.
        uint256 goal = (uint256(pad.getLaunch(t).target) * c.progressBps) / 10_000;
        uint256 k;
        while (!pad.getLaunch(t).complete && pad.getLaunch(t).reserve < goal) {
            vm.broadcast(buyers[k % 4]);
            pad.buy{value: 60 ether}(t, 0);
            ++k;
        }
        if (pad.getLaunch(t).graduated) {
            // a little pool activity after graduation
            for (uint256 j; j < 4; ++j) {
                vm.broadcast(buyers[j]);
                router.buy{value: 2 ether}(t, 2 ether, 0, address(0), block.timestamp + 600);
            }
        }
    }

    /// Avax Hook: dynamic fee, burn, LP rewards, Nth-buy pot, buyback, creator fee with referrals.
    function _houseHooks() internal pure returns (AvaxHook.HookConfig memory h) {
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

    function _hooks(uint256 i) internal pure returns (AvaxHook.HookConfig memory h) {
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
