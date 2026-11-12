// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {HolderDividendsModule} from "../../contracts/v2/modules/HolderDividendsModule.sol";
import {V2Base} from "./V2Base.t.sol";

/// Borrows the token from the PoolManager (flash accounting), tries to fold the pending dividend while holding
/// it (reconcile, or claim), returns it. No capital, no LP. Regression: the borrow itself folds the pending
/// credit at the shares from before it, so the attacker earns nothing.
contract FlashFolder is IUnlockCallback {
    IPoolManager pm;
    HolderDividendsModule div;
    address token;
    bool viaClaim;

    constructor(IPoolManager _pm, HolderDividendsModule _div, address _t) {
        pm = _pm;
        div = _div;
        token = _t;
    }

    function go(bool _viaClaim) external {
        viaClaim = _viaClaim;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        uint256 amt = IERC20(token).balanceOf(address(pm)) - 1;
        pm.take(Currency.wrap(token), address(this), amt);
        if (viaClaim) {
            try div.claim(token) {} catch {}
        } else {
            div.reconcile();
        }
        pm.sync(Currency.wrap(token));
        IERC20(token).transfer(address(pm), amt);
        pm.settle();
        return "";
    }

    receive() external payable {}
}

/// Sells straight on the PoolManager, paying its tokens BEFORE the swap: no token moves after the hook books
/// the sell's dividend, so the credit is still unverified when the transaction ends.
contract PrepaidSeller is IUnlockCallback {
    IPoolManager pm;
    PoolKey key;
    address token;

    constructor(IPoolManager _pm, PoolKey memory _key, address _t) {
        pm = _pm;
        key = _key;
        token = _t;
    }

    function sell(uint256 amt) external {
        pm.unlock(abi.encode(amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amt = abi.decode(data, (uint256));
        Currency t = Currency.wrap(token);
        pm.sync(t);
        IERC20(token).transfer(address(pm), amt);
        pm.settle();
        bool zeroForOne = Currency.unwrap(key.currency0) == token;
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 out = zeroForOne ? d.amount1() : d.amount0();
        pm.take(zeroForOne ? key.currency1 : key.currency0, address(this), uint256(uint128(out)));
        return "";
    }

    receive() external payable {}
}

contract HolderDividendsFlashFoldTest is V2Base {
    HolderDividendsModule div;
    uint32 divId;

    function setUp() public override {
        super.setUp();
        div = new HolderDividendsModule(address(hook));
        divId = modules.addModule(address(div), '{"name":"Holder dividends"}');
    }

    function _launchDiv() internal returns (HookTokenV2 t, PoolKey memory key) {
        uint32[] memory ids = new uint32[](1);
        bytes[] memory cfgs = new bytes[](1);
        ids[0] = divId;
        cfgs[0] = abi.encode(HolderDividendsModule.Config(1_000));
        t = _launch(ids, cfgs, 0);
        key = _graduate(t);
    }

    /// A large sell leaves its dividend unverified past the end of its transaction.
    function _pendingSell() internal returns (HookTokenV2 t, uint256 alice0, uint256 unverified) {
        PoolKey memory key;
        (t, key) = _launchDiv();
        _routerBuy(alice, t, 10 ether);
        PrepaidSeller s = new PrepaidSeller(PM, key, address(t));
        _routerBuy(bob, t, 30 ether);
        uint256 bal = t.balanceOf(bob);
        vm.prank(bob);
        t.transfer(address(s), bal);
        div.reconcile();
        alice0 = div.pending(address(t), alice);
        s.sell(bal);
        unverified = div.stats(address(t)).undistributed;
        assertGt(unverified, 0, "the sell's dividend waits unverified");
    }

    function _check(HookTokenV2 t, FlashFolder f, uint256 alice0, uint256 unverified) internal view {
        assertEq(t.balanceOf(address(f)), 0);
        assertEq(div.sharesOf(address(t), address(f)), 0);
        assertEq(div.pending(address(t), address(f)), 0, "a zero-capital borrower earns nothing");
        assertEq(div.stats(address(t)).undistributed, 0, "the sell's dividend got folded");
        // Folded at the shares from before the borrow: alice gets her pro-rata cut of it.
        uint256 expected = (unverified * div.sharesOf(address(t), alice)) / div.stats(address(t)).totalShares;
        assertApproxEqAbs(div.pending(address(t), alice) - alice0, expected, 2, "the holders keep it all");
    }

    function test_flashFoldViaReconcileGetsNothing() public {
        (HookTokenV2 t, uint256 alice0, uint256 unverified) = _pendingSell();
        FlashFolder f = new FlashFolder(PM, div, address(t));
        f.go(false);
        _check(t, f, alice0, unverified);
    }

    function test_flashFoldViaClaimGetsNothing() public {
        (HookTokenV2 t, uint256 alice0, uint256 unverified) = _pendingSell();
        FlashFolder f = new FlashFolder(PM, div, address(t));
        f.go(true);
        _check(t, f, alice0, unverified);
    }

    /// A router buy's dividend folds when the bought tokens are delivered, before the buyer's shares grow:
    /// nothing is left pending for a borrower, and the buyer earns nothing from their own buy.
    function test_buyFoldsAtDeliveryBuyerExcluded() public {
        (HookTokenV2 t,) = _launchDiv();
        _routerBuy(alice, t, 10 ether);
        uint256 alice0 = div.pending(address(t), alice);
        _routerBuy(bob, t, 20 ether);
        assertEq(div.stats(address(t)).undistributed, 0, "folded within the buy");
        assertEq(div.pending(address(t), bob), 0, "the buyer doesn't earn his own buy's dividend");
        assertGt(div.pending(address(t), alice), alice0);
        FlashFolder f = new FlashFolder(PM, div, address(t));
        f.go(false);
        assertEq(div.pending(address(t), address(f)), 0);
    }
}
