// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {AvaxHook} from "../contracts/AvaxHook.sol";
import {HookLaunchpad} from "../contracts/HookLaunchpad.sol";
import {HookToken} from "../contracts/HookToken.sol";
import {HookTokenFactory} from "../contracts/HookTokenFactory.sol";
import {AvaxHookRouter} from "../contracts/AvaxHookRouter.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";
import {BridgeAttestor} from "../contracts/bridge/BridgeAttestor.sol";
import {StockGateway} from "../contracts/bridge/StockGateway.sol";
import {BridgedStock} from "../contracts/bridge/BridgedStock.sol";

/// Avalanche fork: mNVDA minted by the bridge (as if NVDA had been locked on Robinhood Chain), then
/// used as the quote asset of a launch that graduates into Uniswap v4 and trades.
contract BridgedStockLaunchTest is Test {
    IPoolManager constant PM = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant NVDA_RH = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; // official, Robinhood Chain
    address constant ESCROW_RH = address(0xE5C0); // escrow address on the other chain (only signed over)

    StockGateway gateway;
    BridgedStock mNVDA;
    HookLaunchpad pad;
    AvaxHookRouter router;
    AvaxHook hook;
    uint256[] keys;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));

        // bridge: 2-of-3
        for (uint256 i = 1; i <= 3; ++i) keys.push(uint256(keccak256(abi.encode("v", i))));
        for (uint256 i; i < 3; ++i)
            for (uint256 j = i + 1; j < 3; ++j)
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
        address[] memory vals = new address[](3);
        for (uint256 i; i < 3; ++i) vals[i] = vm.addr(keys[i]);
        gateway = new StockGateway(address(this), 4663);
        gateway.setValidators(vals, 2);
        gateway.setRemote(ESCROW_RH);
        mNVDA = gateway.createStock(NVDA_RH, "NVIDIA (AvaxHook bridged)", "mNVDA");
        gateway.setLimit(NVDA_RH, 1_000 ether);

        // launchpad with mNVDA as a quote, priced by a keeper feed at $234.66
        (, bytes32 salt) = HookMiner.find(address(this), uint160(_flags()), type(AvaxHook).creationCode, abi.encode(address(PM), address(this)));
        hook = new AvaxHook{salt: salt}(PM, address(this));
        HookTokenFactory factory = new HookTokenFactory();
        QuoteRegistry registry = new QuoteRegistry(address(this));
        ManualPriceFeed feed = new ManualPriceFeed(address(this), "mNVDA / USD", 8, 234_66000000);
        registry.setQuote(address(mNVDA), true, address(feed));
        pad = new HookLaunchpad(PM, hook, factory, registry, address(this), makeAddr("treasury"));
        factory.bindLaunchpad(address(pad));
        hook.bindLaunchpad(address(pad));
        router = new AvaxHookRouter(PM, pad);
        hook.bindRouter(address(router));
    }

    function _flags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    /// Mint mNVDA as the relayer would after a lock on Robinhood Chain.
    function _bridgeIn(address to, uint256 amount, uint64 nonce) internal {
        BridgeAttestor.Transfer memory t =
            BridgeAttestor.Transfer(4663, ESCROW_RH, nonce, block.chainid, address(gateway), NVDA_RH, to, amount);
        bytes32 digest = gateway.hashTransfer(t);
        bytes[] memory sigs = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
        gateway.mint(t, sigs);
    }

    function test_bridgedStockPairedLaunch() public {
        _bridgeIn(alice, 100 ether, 1);
        _bridgeIn(bob, 5 ether, 2);
        assertEq(mNVDA.balanceOf(alice), 100 ether);

        HookLaunchpad.LaunchArgs memory a;
        a.name = "Green Team";
        a.symbol = "GPU";
        a.quote = address(mNVDA);
        a.hook.baseFeePips = 3_000;
        a.hook.maxFeePips = 3_000;
        a.hook.burnBps = 100;
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        address t = pad.launch{value: pad.creationFee()}(a);
        mNVDA.approve(address(pad), type(uint256).max);
        pad.buyWithQuote(t, 60 ether, 0); // $2.5k → $50k needs ~38 mNVDA at $234.66; the rest is not taken
        vm.stopPrank();

        HookLaunchpad.Launch memory l = pad.getLaunch(t);
        assertTrue(l.graduated);
        assertApproxEqRel(uint256(l.target), 38.1 ether, 0.02e18); // ≈ $8.9k raise in mNVDA
        assertGt(mNVDA.balanceOf(alice), 100 ether - 40 ether);

        // trade the TOKEN/mNVDA pool, then send mNVDA home to Robinhood
        vm.startPrank(bob);
        mNVDA.approve(address(router), type(uint256).max);
        uint256 out = router.buy(t, 2 ether, 0, address(0), block.timestamp);
        assertGt(out, 0);
        HookToken(t).approve(address(router), out);
        uint256 back = router.sell(t, out, 0, block.timestamp);
        assertGt(back, 1.9 ether);
        uint64 n = gateway.burn(NVDA_RH, mNVDA.balanceOf(bob), bob);
        vm.stopPrank();
        assertEq(n, 1);
        assertEq(mNVDA.balanceOf(bob), 0);
    }
}
