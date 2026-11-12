// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";
import {Seed} from "../script/Seed.s.sol";
import {LaunchHouseCoins} from "../script/LaunchHouseCoins.s.sol";
import {DeployOrders} from "../script/DeployOrders.s.sol";

contract SeedHarness is Seed {
    function houseHooks() external pure returns (AvaxHook.HookConfig memory) {
        return _houseHooks();
    }

    function hooks(uint256 i) external pure returns (AvaxHook.HookConfig memory) {
        return _hooks(i);
    }
}

/// Guards of the deploy/launch scripts. Everything that touches process env lives in one test
/// function, because forge runs tests in parallel and vm.setEnv is process-wide.
contract ScriptFixesTest is Test {
    HookLaunchpad pad;

    function setUp() public {
        PoolManager pm = new PoolManager(address(this));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AvaxHook).creationCode, abi.encode(address(pm), address(this)));
        AvaxHook hook = new AvaxHook{salt: salt}(IPoolManager(address(pm)), address(this));
        HookTokenFactory factory = new HookTokenFactory();
        QuoteRegistry registry = new QuoteRegistry(address(this));
        registry.setQuote(address(0), true, address(new ManualPriceFeed(address(this), "AVAX / USD", 8, 25e8)));
        pad = new HookLaunchpad(IPoolManager(address(pm)), hook, factory, registry, address(this), makeAddr("treasury"));
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
    }

    function test_seed_refusesMainnet() public {
        vm.chainId(43114); // no anvil node behind this "chain"
        Seed s = new Seed();
        vm.expectRevert(bytes("Seed is local-only: refusing to run on Avalanche mainnet"));
        s.run();
    }

    function test_houseCoinHooks_matchSeed() public {
        SeedHarness s = new SeedHarness();
        LaunchHouseCoins l = new LaunchHouseCoins();
        assertEq(keccak256(abi.encode(l.houseHooks())), keccak256(abi.encode(s.houseHooks())));
        for (uint256 i; i < 5; ++i) assertEq(keccak256(abi.encode(l.coinHooks(i))), keccak256(abi.encode(s.hooks(i))));
    }

    function test_envGuards() public {
        LaunchHouseCoins l = new LaunchHouseCoins();
        vm.setEnv("LAUNCHPAD", vm.toString(address(pad)));
        vm.setEnv("DEV_BUY_WEI", "0");

        // anvil default keys are refused, whichever index
        vm.setEnv("DEPLOYER_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"); // #0
        vm.expectRevert(bytes("DEPLOYER_KEY is an anvil default key"));
        l.run();
        vm.setEnv("DEPLOYER_KEY", "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"); // #9
        vm.expectRevert(bytes("DEPLOYER_KEY is an anvil default key"));
        l.run();

        // a real key launches all six, AVAX-paired, with Seed's hook configs, no buys
        uint256 key = uint256(keccak256("house coin deployer"));
        address creator = vm.addr(key);
        vm.setEnv("DEPLOYER_KEY", vm.toString(bytes32(key)));
        vm.expectRevert(bytes("deployer balance too low for 6 launches"));
        l.run();
        vm.deal(creator, 1 ether);
        address[] memory t = l.run();
        assertEq(t.length, 6);
        SeedHarness s = new SeedHarness();
        string[6] memory symbols = ["HOOK", "HWHALE", "HCAT", "HDOG", "HSHARK", "VARIUM"];
        for (uint256 i; i < 6; ++i) {
            HookLaunchpad.Launch memory info = pad.getLaunch(t[i]);
            assertEq(info.creator, creator);
            assertEq(info.quote, address(0));
            assertEq(info.reserve, 0);
            assertEq(HookToken(t[i]).symbol(), symbols[i]);
            assertEq(
                keccak256(abi.encode(info.hook)), keccak256(abi.encode(i == 0 ? s.houseHooks() : s.hooks(i - 1)))
            );
        }
        assertEq(HookToken(t[0]).name(), "Avax Hook");
        assertEq(creator.balance, 1 ether - 6 * pad.creationFee());

        // optional dev-buy
        vm.setEnv("DEV_BUY_WEI", "100000000000000000"); // 0.1 AVAX each
        vm.deal(creator, 2 ether);
        t = l.run();
        for (uint256 i; i < 6; ++i) {
            assertGt(HookToken(t[i]).balanceOf(creator), 0);
            assertGt(pad.getLaunch(t[i]).reserve, 0);
        }
        vm.setEnv("DEV_BUY_WEI", "0");

        // DeployOrders: on mainnet without OWNER it needs the explicit EOA opt-in
        vm.chainId(43114);
        vm.setEnv("ADMIN_PRIVATE_KEY", vm.toString(bytes32(key)));
        vm.setEnv("OWNER", vm.toString(address(0)));
        vm.setEnv("ALLOW_EOA_OWNER", "false");
        DeployOrders d = new DeployOrders();
        vm.expectRevert(bytes("set OWNER (multisig/timelock) or ALLOW_EOA_OWNER=true"));
        d.run();
    }
}
