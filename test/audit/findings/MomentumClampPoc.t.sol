// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookModule} from "../../../contracts/v2/interfaces/IHookModule.sol";
import {MomentumModule} from "../../../contracts/v2/modules/MomentumModule.sol";
import {CoupledResonatorModule} from "../../../contracts/v2/modules/CoupledResonatorModule.sol";

/// Regression (was a PoC): the radius clamp moved the cosine term (the cap) in the SAME second as a buy, so a
/// front-runner's buy could shrink the cap seen by a victim's buy in the same second. Both modules now fix the
/// cap at the first buy of each second (like Resonance); the kick shows from the next second.
/// This test plays the hook itself (unit test, no fork).
contract MomentumClampPoc is Test {
    MomentumModule mom;
    CoupledResonatorModule cpl;
    PoolId constant ID = PoolId.wrap(bytes32(uint256(0xabc)));
    address constant TOKEN = address(0x1234);
    uint256 constant BASE = 100_000_000 ether; // 10% of 1B

    function poolManager() external pure returns (address) {
        return address(0);
    }

    function setUp() public {
        mom = new MomentumModule(address(this));
        cpl = new CoupledResonatorModule(address(this));
        vm.warp(1_000_000);
    }

    function _ctx(uint256 out) internal pure returns (IHookModule.SwapContext memory c) {
        c.poolId = ID;
        c.token = TOKEN;
        c.isBuy = true;
        c.amountOut = out;
    }

    // Run with --isolate: every external call is its own transaction (fresh transient tally).
    function _buy(uint256 out) internal {
        mom.onAfterSwap(_ctx(out));
    }

    /// forge-config: default.isolate = true

    function test_momentum_sameSecondCapDrop() public {
        // base 10%, floor 0.1%, period 40 s, damping 0.01%/s, energy 100%
        mom.onRegister(ID, TOKEN, address(0), address(0), abi.encode(MomentumModule.Config(1000, 10, 40, 1, 10_000)));
        for (uint256 i; i < 4; ++i) {
            _buy(mom.currentCap(TOKEN)); // kicks add up on the sine term (one full period apart)
            vm.warp(block.timestamp + (i == 3 ? 10 : 40)); // last: a quarter period, the swing sits in the cap
        }
        uint256 before = mom.currentCap(TOKEN);
        console2.log("cap before, x base (1e18)", (before * 1e18) / BASE);
        _buy(before); // attacker tx (sells back later; sells don't move the oscillator)
        uint256 afterCap = mom.currentCap(TOKEN);
        console2.log("cap same second after one buy, x base", (afterCap * 1e18) / BASE);
        assertEq(afterCap, before, "cap fixed for the rest of the second");
        _buy(before); // victim's buy in the same second still fits the full cap
        vm.warp(block.timestamp + 1);
        assertLt(mom.currentCap(TOKEN), (before * 80) / 100, "the clamp shows from the next second");
    }

    /// forge-config: default.isolate = true

    function test_coupled_sameSecondCapMoves() public {
        cpl.onRegister(
            ID, TOKEN, address(0), address(0), abi.encode(CoupledResonatorModule.Config(1000, 10, 40, 40, 2500, 1, 10_000))
        );
        uint256 hi;
        uint256 nextMoved;
        for (uint256 i; i < 12; ++i) {
            uint256 b4 = cpl.currentCap(TOKEN);
            cpl.onAfterSwap(_ctx(b4));
            uint256 af = cpl.currentCap(TOKEN);
            if (af != b4) hi = af > b4 ? af - b4 : b4 - af;
            cpl.onAfterSwap(_ctx(b4)); // a second buy in the same second sees the same cap
            vm.warp(block.timestamp + 10);
            if (cpl.currentCap(TOKEN) != b4) ++nextMoved;
        }
        assertEq(hi, 0, "cap never moves within the second");
        assertGt(nextMoved, 0, "kicks still move the cap later");
    }
}
