// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Fork check that candidate quote coins are plain ERC-20s: exact transfers, no fee, no rebase.
contract QuoteTokenCheck is Test {
    function test_candidateQuotesArePlainErc20() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")));
        address[10] memory t = [
            0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7,
            0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd,
            0x60781C2586D68229fde47564546784ab3fACA982,
            0x420FcA0121DC28039145009570975747295f2329,
            0xFFFF003a6BAD9b743d658048742935fFFE2b6ED7,
            0x18E3605B13F10016901eAC609b9E188CF7c18973,
            0xB8d7710f7d8349A506b75dD184F05777c82dAd0C,
            0xAcFb898Cff266E53278cC0124fC2C7C94C8cB9a5,
            0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6,
            0x34a1D2105dd1b658A48EAD516A9CE3032082799C
        ];
        address a = makeAddr("a");
        address b = makeAddr("b");
        for (uint256 i; i < t.length; ++i) {
            deal(t[i], a, 1e24);
            vm.prank(a);
            IERC20(t[i]).transfer(b, 1e21);
            bool exact = IERC20(t[i]).balanceOf(b) == 1e21 && IERC20(t[i]).balanceOf(a) == 1e24 - 1e21;
            vm.prank(b);
            IERC20(t[i]).approve(a, 1e21);
            vm.prank(a);
            IERC20(t[i]).transferFrom(b, a, 1e21);
            exact = exact && IERC20(t[i]).balanceOf(a) == 1e24 && IERC20(t[i]).balanceOf(b) == 0;
            console2.log(t[i], exact ? "plain" : "NOT PLAIN");
            assertTrue(exact);
        }
    }
}
