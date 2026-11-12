// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookTokenV2} from "../../../contracts/v2/HookTokenV2.sol";
import {AvaxHookRouterV2} from "../../../contracts/v2/AvaxHookRouterV2.sol";
import {ModuleCaps} from "../../../contracts/v2/interfaces/IHookModule.sol";
import {ConvictionCapModule} from "../../../contracts/v2/modules/ConvictionCapModule.sol";
import {GraduatedSellCapModule} from "../../../contracts/v2/modules/GraduatedSellCapModule.sol";
import {NewModulesBase} from "../../v2/NewModulesBase.t.sol";
import {ListsLaunderer} from "../final/ListsFinal.t.sol";

contract Parking {
    function back(IERC20 t, address to) external {
        t.transfer(to, t.balanceOf(address(this)));
    }
}

/// One transaction: park the bag in a second wallet, sell dust (records a tiny bag), pull the bag back, sell big.
contract BagParker {
    AvaxHookRouterV2 immutable router;
    Parking immutable park;

    constructor(AvaxHookRouterV2 _router) {
        router = _router;
        park = new Parking();
    }

    receive() external payable {}

    function run(address token, uint256 keep, uint256 dust, uint256 big) external {
        IERC20 t = IERC20(token);
        t.transfer(address(park), t.balanceOf(address(this)) - keep);
        t.approve(address(router), type(uint256).max);
        router.sell(token, dust, 0, block.timestamp, "");
        park.back(t, address(this));
        router.sell(token, big, 0, block.timestamp, "");
    }
}

/// ConvictionCap: LP withdrawals / fee collects of this pool are not buys (LP-removal allowance).
/// forge-config: default.isolate = true
contract ConvictionLpPoc is NewModulesBase {
    ConvictionCapModule cc;
    uint32 ccId;
    HookTokenV2 t;
    PoolKey key;
    uint256 constant START = 5_000_000 ether; // 0.5%

    function setUp() public override {
        super.setUp();
        cc = new ConvictionCapModule(address(hook));
        ccId = modules.addModule(address(cc), '{"name":"Conviction cap"}');
        // 0.5% start, +0.5%/day, 2% ceiling, forever (duration 0)
        (t, key) = _launchCapped(ccId, abi.encode(ConvictionCapModule.Config(50, 50, 1 days, 200, 0)), 4_500_000 ether, 0);
    }

    function _range(int256 liq) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), liq, 0);
    }

    function test_capabilitiesIncludeLiquidity() public view {
        assertEq(cc.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY);
    }

    function test_bigLpWithdrawsInOneTx() public {
        address lpUser = makeAddr("bigLp");
        deal(address(t), lpUser, 200_000_000 ether);
        vm.deal(lpUser, 10_000 ether);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        vm.startPrank(lpUser);
        t.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 5_000 ether}(key, _range(3e22), "");
        vm.stopPrank();
        uint256 b0 = t.balanceOf(lpUser);
        // fresh clock: the add restarted it, so the cap is the start cap
        vm.prank(lpUser);
        lp.modifyLiquidity(key, _range(-3e22), "");
        uint256 got = t.balanceOf(lpUser) - b0;
        assertGt(got, START, "withdrawal larger than the cap, in one transaction");
        // real buys are still capped
        bytes memory err = _buyError(lpUser, t, 200 ether);
        assertTrue(_has(err, ConvictionCapModule.BuyCapExceeded.selector));
    }

    /// A buy parked as liquidity and pulled out in the same transaction gets no allowance.
    function test_sameTxAddRemoveStillCapped() public {
        ListsLaunderer l = new ListsLaunderer(PM);
        vm.deal(address(l), 1_000 ether);
        vm.expectRevert();
        l.run(key, 200 ether, 1e18, bob);
    }
}

/// GraduatedSellCap: the bag is the largest balance before any sell in the transaction.
/// forge-config: default.isolate = true
contract GraduatedBagPoc is NewModulesBase {
    GraduatedSellCapModule gs;
    uint32 gsId;
    HookTokenV2 t;
    PoolKey key;
    uint256 constant HI = 10_000_000 ether; // 1% cap for small bags
    uint256 constant LO = 1_000_000 ether; // 0.1% floor cap

    function setUp() public override {
        super.setUp();
        gs = new GraduatedSellCapModule(address(hook));
        gsId = modules.addModule(address(gs), '{"name":"Graduated sell caps"}');
        (t, key) = _launchOne(gsId, abi.encode(GraduatedSellCapModule.Config(50, 100, 300, 10, 0)));
    }

    function _whaleParker() internal returns (BagParker p) {
        p = new BagParker(router);
        for (uint256 i; i < 10; ++i) {
            address w = _holder(i);
            uint256 b = t.balanceOf(w);
            vm.prank(w);
            t.transfer(address(p), b);
        }
        assertGt(t.balanceOf(address(p)), 30_000_000 ether); // a whale bag (>= 3%)
    }

    function test_parkedBagStillWhale() public {
        BagParker p = _whaleParker();
        try p.run(address(t), 1 ether, 0.5 ether, HI / 2) {
            fail();
        } catch (bytes memory err) {
            assertTrue(_has(err, GraduatedSellCapModule.SellCapExceeded.selector));
        }
        // within the whale's floor cap it goes through
        p.run(address(t), 1 ether, 0.5 ether, LO / 2);
    }
}
