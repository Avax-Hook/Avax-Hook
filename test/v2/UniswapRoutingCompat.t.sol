// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface ILaunchpadKey {
    function poolKey(address token) external view returns (PoolKey memory);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Pre-allowlist check (Uniswap routing): the LIVE v2 hook's HOOK/AVAX pool, traded through Uniswap's
/// LIVE UniversalRouter (V4_SWAP, empty hookData) and quoted with the LIVE V4Quoter, on a mainnet fork.
/// The Avalanche deployments predate `minHopPriceX36`, so the old ExactInputSingleParams layout is encoded.
contract UniswapRoutingCompatTest is Test {
    address constant LAUNCHPAD_V2 = 0x922A73Bd8aC4db8729aADE7a09288Da536058F02;
    address constant HOOK_TOKEN = 0x898D93e5BF6ee61a03f50CB0cdBF9C3751dA8Dc7;
    IUniversalRouter constant UR = IUniversalRouter(0x94b75331AE8d42C1b61065089B7d48FE14aA73b7);
    address constant V4_QUOTER = 0xbE40675BB704506a3c2Ccfb762DCFd1e979845C2;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    struct ExactInputSingleParamsOld {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct ExactOutputSingleParamsOld {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    address trader = makeAddr("trader");
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        key = ILaunchpadKey(LAUNCHPAD_V2).poolKey(HOOK_TOKEN);
        vm.deal(trader, 100 ether);
    }

    function _quote(bool zeroForOne, uint128 amount) internal returns (uint256 out) {
        (bool ok, bytes memory ret) = V4_QUOTER.call(
            abi.encodeWithSignature(
                "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
                QuoteExactSingleParams(key, zeroForOne, amount, "")
            )
        );
        require(ok, "quoter reverted");
        (out,) = abi.decode(ret, (uint256, uint256));
    }

    function _urExactIn(bool zeroForOne, uint128 amountIn, uint256 value) internal {
        (Currency inC, Currency outC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParamsOld(key, zeroForOne, amountIn, 0, ""));
        params[1] = abi.encode(inC, uint256(amountIn));
        params[2] = abi.encode(outC, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(trader);
        UR.execute{value: value}(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
    }

    function test_universalRouterBuyAndSellMatchQuoter() public {
        assertEq(Currency.unwrap(key.currency0), address(0), "AVAX is currency0");
        // buy: AVAX -> HOOK
        uint256 q = _quote(true, 1 ether);
        uint256 b0 = IERC20(HOOK_TOKEN).balanceOf(trader);
        _urExactIn(true, 1 ether, 1 ether);
        uint256 got = IERC20(HOOK_TOKEN).balanceOf(trader) - b0;
        console2.log("UR buy 1 AVAX -> HOOK", got, "quoter", q);
        assertEq(got, q, "buy matches V4Quoter");

        // sell: HOOK -> AVAX through Permit2
        vm.startPrank(trader);
        IERC20(HOOK_TOKEN).approve(PERMIT2, type(uint256).max);
        (bool ok,) = PERMIT2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)", HOOK_TOKEN, address(UR), type(uint160).max, uint48(block.timestamp + 1 hours)
            )
        );
        require(ok);
        vm.stopPrank();
        uint256 qs = _quote(false, uint128(got));
        uint256 a0 = trader.balance;
        _urExactIn(false, uint128(got), 0);
        console2.log("UR sell HOOK -> AVAX", trader.balance - a0, "quoter", qs);
        assertEq(trader.balance - a0, qs, "sell matches V4Quoter");
    }

    /// The hook refuses exact-output swaps (ExactOutputBlocked): routing must use exact-in only.
    function test_exactOutputRefused() public {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactOutputSingleParamsOld(key, true, 1_000 ether, 1 ether, ""));
        params[1] = abi.encode(key.currency0, uint256(1 ether));
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(trader);
        vm.expectRevert();
        UR.execute{value: 1 ether}(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
    }
}
