// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookRouterV2} from "../../contracts/v2/AvaxHookRouterV2.sol";
import {GrudgeModule} from "../../contracts/v2/modules/GrudgeModule.sol";
import {HolderVestingModule} from "../../contracts/v2/modules/HolderVestingModule.sol";
import {ConvictionCapModule} from "../../contracts/v2/modules/ConvictionCapModule.sol";
import {NewModulesBase} from "../v2/NewModulesBase.t.sol";

/// A smart wallet / 7702 batch: self-transfer, then sell everything through the AvaxHook router.
contract BatchWallet {
    AvaxHookRouterV2 immutable router;

    constructor(AvaxHookRouterV2 r) {
        router = r;
    }

    receive() external payable {}

    function selfShuffleThenDump(address token) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(address(this), bal); // self-transfer: counted as "received this tx"
        IERC20(token).approve(address(router), bal);
        router.sell(token, bal, 0, block.timestamp, "");
    }

    /// A -> B -> A inside one transaction, then sell everything.
    function bounceThenDump(address token, Bouncer b) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(address(b), bal);
        b.back(token);
        IERC20(token).approve(address(router), bal);
        router.sell(token, bal, 0, block.timestamp, "");
    }

    function dump(address token) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(address(router), bal);
        router.sell(token, bal, 0, block.timestamp, "");
    }
}

/// Sends everything it holds back to the caller.
contract Bouncer {
    function back(address token) external {
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }
}

/// A PoolManager caller that buys and has the output taken straight to someone else.
contract GiftBuyer is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function buyFor(PoolKey calldata key, uint256 amountIn, address to) external payable {
        pm.unlock(abi.encode(key, amountIn, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        // quote = native = currency0 in these tests
        pm.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        pm.settle{value: uint256(-pm.currencyDelta(address(this), key.currency0))}();
        pm.take(key.currency1, to, uint256(pm.currencyDelta(address(this), key.currency1)));
        return "";
    }
}

/// forge-config: default.isolate = true
contract LimitsAuditTest is NewModulesBase {
    GrudgeModule gm;
    uint32 gmId;
    HolderVestingModule hv;
    uint32 hvId;
    ConvictionCapModule cc;

    function setUp() public override {
        super.setUp();
        gm = new GrudgeModule(address(hook));
        gmId = modules.addModule(address(gm), '{"name":"The grudge"}');
        hv = new HolderVestingModule(address(hook));
        hvId = modules.addModule(address(hv), '{"name":"Holder vesting"}');
        cc = new ConvictionCapModule(address(hook));
    }

    function _gcfg() internal pure returns (bytes memory) {
        // a dump = 50% of the bag; 1 hour doubling to 30 days; BUY_BAN
        return abi.encode(GrudgeModule.Config(5_000, 1 hours, 30 days, 0, 0, 0));
    }

    /// M-1 (fixed): 1 wei of dust sent to an aggregator contract no longer makes a pass-through sell its dump:
    /// the bag is its balance before its first touch, and tokens it received in the transaction are netted out.
    function test_M1_grudge_dustCantPoisonAggregator() public {
        (HookTokenV2 t, PoolKey memory key) = _launchOne(gmId, _gcfg());
        address h = _holder(5);
        vm.prank(_holder(7));
        t.transfer(address(agg), 1);
        uint256 amt = t.balanceOf(h) / 10;
        vm.prank(h);
        t.approve(address(agg), amt);
        agg.sellFrom(key, address(t), h, amt);
        (, uint256 count, bool active) = gm.grudgeOf(address(t), address(agg));
        assertEq(count, 0, "aggregator not grudged");
        assertFalse(active);
        (, count,) = gm.grudgeOf(address(t), h);
        assertEq(count, 0, "seller's hand-off is not a dump");
        agg.swap(key, true, -int256(1 ether)); // aggregator buys keep working
    }

    /// M-2 (fixed): a self-transfer, or bouncing the bag A -> B -> A, before selling no longer hides a dump.
    function test_M2_grudge_selfTransferAndBounceSeen() public {
        (HookTokenV2 t,) = _launchOne(gmId, _gcfg());
        BatchWallet w1 = new BatchWallet(router);
        BatchWallet w2 = new BatchWallet(router);
        BatchWallet w3 = new BatchWallet(router);
        Bouncer bouncer = new Bouncer();
        uint256 bal = t.balanceOf(_holder(5));
        vm.startPrank(_holder(5));
        t.transfer(address(w1), bal / 3);
        t.transfer(address(w2), bal / 3);
        t.transfer(address(w3), bal / 3);
        vm.stopPrank();
        // separate transactions (isolate = true)
        w1.dump(address(t));
        (, uint256 c1,) = gm.grudgeOf(address(t), address(w1));
        assertEq(c1, 1, "plain dump is seen");
        w2.selfShuffleThenDump(address(t));
        (, uint256 c2,) = gm.grudgeOf(address(t), address(w2));
        assertEq(c2, 1, "self-shuffle dump is seen");
        assertEq(t.balanceOf(address(w2)), 0, "sold everything");
        w3.bounceThenDump(address(t), bouncer);
        (, uint256 c3,) = gm.grudgeOf(address(t), address(w3));
        assertEq(c3, 1, "A -> B -> A dump is seen");
        (, uint256 cb,) = gm.grudgeOf(address(t), address(bouncer));
        assertEq(cb, 0);
    }

    /// L-1 (fixed): a third party pushing a qualifying buy straight to a victim can't delay the victim's
    /// schedule: the merge keeps the start, so the original tokens unlock on time.
    function test_L_vesting_thirdPartyBuyCantDelayVictim() public {
        // window 0 (all buys), min 0.1%, cliff 30 days, then 100% after one period of 1 minute
        (HookTokenV2 t, PoolKey memory key) =
            _launchOne(hvId, abi.encode(HolderVestingModule.Config(0, 10, 30 days, 10_000, 60)));
        address victim = _holder(3);
        (uint256 lockedBefore,, uint256 startBefore, uint256 unlockAtBefore) = hv.vestingOf(address(t), victim);
        assertGt(lockedBefore, 0);
        vm.warp(unlockAtBefore - 1 days);
        GiftBuyer g = new GiftBuyer(PM);
        vm.deal(address(this), 1_000 ether);
        // Since the 2026-11-12 claims-bypass guard a direct PoolManager buy is refused (RouterOnly) while buys
        // vest, and a router buy always pays its tokens to the buyer, so a pool gift can't even be pushed now.
        try g.buyFor{value: 200 ether}(key, 200 ether, victim) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
        (uint256 lockedAfter,, uint256 startAfter, uint256 unlockAtAfter) = hv.vestingOf(address(t), victim);
        assertEq(lockedAfter, lockedBefore);
        assertEq(startAfter, startBefore);
        assertEq(unlockAtAfter, unlockAtBefore, "not delayed");
        vm.warp(unlockAtBefore);
        (uint256 stillLocked,,,) = hv.vestingOf(address(t), victim);
        assertEq(stillLocked, 0);
        uint256 bal = t.balanceOf(victim);
        vm.prank(victim);
        t.transfer(alice, bal);
    }

    /// I-1 (fixed): capOf returns zeros for a token that does not use the module.
    function test_I_conviction_capOfUnknownTokenIsZero() public view {
        (uint256 cap, uint256 since, bool active) = cc.capOf(address(0xdead1), alice);
        assertEq(cap, 0);
        assertEq(since, 0);
        assertFalse(active);
    }
}
