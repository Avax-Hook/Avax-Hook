// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {PolarityModule} from "../../contracts/v2/modules/PolarityModule.sol";
import {PolarityModuleTest} from "../v2/PolarityModule.t.sol";

/// Parks tokens in the PoolManager (sync/transfer/settle) inside an unlock so they drop out of `circulating`,
/// redeems a small slice at the inflated per-token rate, then takes the parked tokens back. Repeats `k` times.
contract ParkingRedeemer is IUnlockCallback {
    IPoolManager immutable pm;
    PolarityModule immutable pol;
    address immutable token;

    constructor(IPoolManager _pm, PolarityModule _pol, address _token) {
        pm = _pm;
        pol = _pol;
        token = _token;
        IERC20(_token).approve(address(_pol), type(uint256).max);
    }

    receive() external payable {}

    function warm(uint256 a) external {
        pol.redeem(token, a, 0);
    }

    function run(uint256 k) external {
        pm.unlock(abi.encode(k));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 k = abi.decode(data, (uint256));
        uint256 h = IERC20(token).balanceOf(address(this));
        uint256 slice = h / k;
        Currency c = Currency.wrap(token);
        for (uint256 i; i < k; ++i) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 y = i == k - 1 ? bal : slice;
            uint256 park = bal - y;
            if (park > 0) {
                pm.sync(c);
                IERC20(token).transfer(address(pm), park);
                pm.settle();
            }
            pol.redeem(token, y, 0);
            if (park > 0) pm.take(c, address(this), park);
        }
        return "";
    }
}

contract PolarityAuditTest is PolarityModuleTest {
    /// H-1: parking tokens in the PoolManager during an unlock lets a large holder redeem far more than
    /// its pro-rata share of the side pot, at the other holders' expense.
    function test_audit_parkInPoolManagerInflatesRedeem() public {
        (HookTokenV2 bull,) = _pair(20);
        // the attacker buys ~65% of the curve, 20 other wallets the rest
        _curveBuy(alice, bull, (uint256(pad.getLaunch(address(bull)).target) * 65) / 100);
        _graduateN(bull, 20, 0);
        // pool trading fills the BULL pot
        for (uint256 i; i < 5; ++i) {
            uint256 got = _routerBuy(carol, bull, 50 ether);
            _routerSell(carol, bull, got);
        }
        // attacker buys a position about as big as everyone else's together
        uint256 h = bull.balanceOf(alice);
        uint256 circ = pol.circulating(address(bull));
        uint256 fair = pol.previewRedeem(address(bull), h);
        (uint256 pot,,,) = _pots(bull);
        emit log_named_decimal_uint("attacker share of circulating %", (h * 1e18) / circ * 100, 18);
        emit log_named_decimal_uint("pot", pot, 18);
        emit log_named_decimal_uint("fair payout (redeem all at once)", fair, 18);

        ParkingRedeemer atk = new ParkingRedeemer(PM, pol, address(bull));
        vm.prank(alice);
        bull.transfer(address(atk), h);
        // one small redeem outside the unlock pulls every module claim into `cash` (the hook's claim needs an
        // unlock of its own); from then on redeems inside an unlock are paid from cash
        atk.warm(h / 1000);
        fair = pol.previewRedeem(address(bull), bull.balanceOf(address(atk)));
        (pot,,,) = _pots(bull);
        // FIXED: redeem refuses to run while the PoolManager is unlocked, so the parking loop reverts
        vm.expectRevert();
        atk.run(25);
        // and parking outside an unlock doesn't help: PoolManager balances count as circulating
        uint256 circ0 = pol.circulating(address(bull));
        uint256 h2 = bull.balanceOf(address(atk));
        vm.prank(address(atk));
        bull.transfer(address(PM), h2 / 2);
        assertEq(pol.circulating(address(bull)), circ0, "parking doesn't shrink circulating");
        // redeeming the rest pays exactly pro rata, never more than the fair share of the whole stake
        uint256 before = address(atk).balance;
        atk.warm(h2 - h2 / 2);
        uint256 paid = address(atk).balance - before;
        assertLe(paid, fair, "never more than pro rata");
        assertApproxEqRel(paid, (pot * (h2 - h2 / 2)) / circ0, 1e9);
        (uint256 potAfter,,,) = _pots(bull);
        assertEq(potAfter, pot - paid, "the rest stays for the other holders");
    }

    /// M: once the Safe disables the module, anyone can send BOTH side pots (the holders' redeem floor) to the
    /// creator via rescue(); holders who did not redeem first lose it.
    function test_audit_rescuePaysHoldersPotToCreator() public {
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(20);
        _graduateN(bull, 20, 0);
        uint256 got = _routerBuy(carol, bull, 50 ether);
        _routerSell(carol, bull, got);
        _curveBuy(bob, bear, 10 ether);
        (uint256 pb, uint256 ps,,) = _pots(bull);
        assertGt(pb + ps, 0);
        vm.prank(address(modules));
        hook.disableModule(address(pol));
        // FIXED: no rescue; the pots stay the holders' redeem floor after a disable
        vm.prank(creator);
        vm.expectRevert(PolarityModule.NoRescue.selector);
        pol.rescue(address(bull));
        vm.expectRevert(PolarityModule.NoRescue.selector);
        pol.rescue(address(bear));
        uint256 hb = bull.balanceOf(_holder(0));
        uint256 fair = pol.previewRedeem(address(bull), hb);
        vm.startPrank(_holder(0));
        bull.approve(address(pol), type(uint256).max);
        uint256 paid = pol.redeem(address(bull), hb, 0);
        vm.stopPrank();
        assertGt(paid, 0, "holders still redeem after a disable");
        assertEq(paid, fair);
    }
}

contract PolarityGasAudit is PolarityModuleTest {
    /// Gas of the module's buy callback with the real (unmocked) live feed, cold slots: must stay well under the
    /// hook's 200k budget, or every buy reverts (the buy path is not isolated).
    function test_audit_gasRealFeed() public {
        (HookTokenV2 bull, HookTokenV2 bear) = _pair(20);
        vm.clearMockedCalls();
        _curveBuy(alice, bull, 1 ether);
        _curveBuy(alice, bear, 1 ether);
        (,, uint256 pLast,) = _pots(bull);
        emit log_named_uint("pLast (live feed)", pLast);
    }
}

contract PolarityAsymmetryAudit is PolarityModuleTest {
    /// M: the shift is a fraction of the LOSER's pot only, so a side with a tiny pot risks almost nothing and wins
    /// up to half the other pot. A creator who pairs late (BEAR pot ~0, BEAR supply held by the creator) gets a
    /// free leveraged put on the BULL holders' pot.
    function test_audit_emptyBearIsAFreeOption() public {
        HookTokenV2 bull = _launchAs(creator, _cfg(0, 50, FEE, address(0)));
        _graduateN(bull, 20, 0); // BULL pot fills from the whole curve
        HookTokenV2 bear = _launchAs(creator, _cfg(1, 50, FEE, address(bull)));
        _curveBuy(creator, bear, 0.01 ether);
        (uint256 b0, uint256 s0,,) = _pots(bull);
        emit log_named_decimal_uint("BULL pot", b0, 18);
        emit log_named_decimal_uint("BEAR pot (at risk)", s0, 18);
        // price up 10%: BULL wins 50% of a dust pot
        _mockAvaxUsd(22e18);
        pol.sync(address(bull));
        (uint256 b1, uint256 s1,,) = _pots(bull);
        emit log_named_decimal_uint("BULL gain on +10%", b1 - b0, 18);
        // back to 20 then down 10%: BEAR wins half of the BULL pot
        _mockAvaxUsd(18e18);
        pol.sync(address(bull));
        (uint256 b2, uint256 s2,,) = _pots(bull);
        emit log_named_decimal_uint("BEAR pot after -18%", s2, 18);
        // FIXED: shifts are a share of the SMALLER pot, so the dust BEAR side can win at most what it risked
        assertLe(s2, s0 * 2, "BEAR never wins more than its own pot's size");
        assertGe(b2, b0 - s0, "BULL holders lose at most the BEAR pot's size");
        assertLt(b1 - b0, 0.01 ether);
        s1;
        b2;
    }
}
