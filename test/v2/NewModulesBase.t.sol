// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {AvaxHookRouterV2} from "../../contracts/v2/AvaxHookRouterV2.sol";
import {HookLaunchpadV2} from "../../contracts/v2/HookLaunchpadV2.sol";
import {QuoteRegistry} from "../../contracts/QuoteRegistry.sol";
import {V2Base} from "./V2Base.t.sol";

/// Shared helpers for the module tests written from HOOKS-BACKLOG.md.
abstract contract NewModulesBase is V2Base {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function _one(uint32 id) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](1);
        ids[0] = id;
    }

    function _oneCfg(bytes memory c) internal pure returns (bytes[] memory cfgs) {
        cfgs = new bytes[](1);
        cfgs[0] = c;
    }

    function _launchOne(uint32 id, bytes memory cfg) internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(_one(id), _oneCfg(cfg), 0);
        key = _graduateN(t, 40, 0);
    }

    /// Like _launchOne, but every curve buy receives at most `maxTokens` (rules with per-buy caps run on the
    /// curve too), `spacing` seconds apart.
    function _launchCapped(uint32 id, bytes memory cfg, uint256 maxTokens, uint256 spacing)
        internal
        returns (HookTokenV2 t, PoolKey memory key)
    {
        t = _launch(_one(id), _oneCfg(cfg), 0);
        key = _graduateCapped(t, maxTokens, spacing);
    }

    function _graduateCapped(HookTokenV2 t, uint256 maxTokens, uint256 spacing) internal returns (PoolKey memory key) {
        for (uint256 i; i < 2000 && !pad.getLaunch(address(t)).complete; ++i) {
            if (i > 0 && spacing > 0) vm.warp(vm.getBlockTimestamp() + spacing);
            HookLaunchpadV2.Launch memory l = pad.getLaunch(address(t));
            uint256 x = uint256(l.virtualQuote) + l.reserve;
            uint256 y = uint256(l.virtualTokens) - l.tokensSold;
            // net quote for maxTokens on x*y=k, grossed up for the 0.3% + creator fee, 2% margin
            uint256 net = (x * maxTokens) / (y - maxTokens);
            uint256 gross = (net * 9_800) / (10_000 - 30 - l.creatorFeeBps);
            address w = _holder(i);
            vm.deal(w, w.balance + gross * 2 + 1 ether);
            vm.prank(w);
            pad.buy{value: gross}(address(t), 0);
        }
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        key = pad.poolKey(address(t));
    }

    /// Fills the curve with `n` equal buys (target / n) from fresh wallets, `spacing` seconds apart (rules
    /// run on the curve too: caps need small buys, ping pong needs its timeout between buys).
    function _graduateN(HookTokenV2 t, uint256 n, uint256 spacing) internal returns (PoolKey memory key) {
        uint256 chunk = uint256(pad.getLaunch(address(t)).target) / n;
        for (uint256 i; i < 3 * n && !pad.getLaunch(address(t)).complete; ++i) {
            if (i > 0 && spacing > 0) vm.warp(vm.getBlockTimestamp() + spacing);
            address w = _holder(i);
            vm.deal(w, w.balance + chunk * 2);
            vm.prank(w);
            pad.buy{value: chunk}(address(t), 0);
        }
        assertTrue(pad.getLaunch(address(t)).graduated, "graduated");
        key = pad.poolKey(address(t));
    }

    /// Router buy that is expected to revert (the PoolManager wraps the module's error).
    function _buyReverts(address who, HookTokenV2 t, uint256 amt) internal {
        vm.prank(who);
        vm.expectRevert();
        router.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "");
    }

    function _sellReverts(address who, HookTokenV2 t, uint256 amt) internal {
        vm.startPrank(who);
        t.approve(address(router), amt);
        vm.expectRevert();
        router.sell(address(t), amt, 0, block.timestamp, "");
        vm.stopPrank();
    }

    /// Error bytes of a router buy, for checking the module's error inside the PoolManager's wrapper.
    function _buyError(address who, HookTokenV2 t, uint256 amt) internal returns (bytes memory err) {
        vm.prank(who);
        try router.buy{value: amt}(address(t), amt, 0, address(0), block.timestamp, "") {
            revert("buy did not revert");
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _sellError(address who, HookTokenV2 t, uint256 amt) internal returns (bytes memory err) {
        vm.startPrank(who);
        t.approve(address(router), amt);
        try router.sell(address(t), amt, 0, block.timestamp, "") {
            revert("sell did not revert");
        } catch (bytes memory e) {
            err = e;
        }
        vm.stopPrank();
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function _has(bytes memory err, bytes4 sel) internal pure returns (bool) {
        return _contains(err, abi.encodePacked(sel));
    }

    /// Fixes the live QuoteRegistry's AVAX/USD price (18 decimals) for market-cap reads by modules.
    function _mockAvaxUsd(uint256 price) internal {
        vm.mockCall(address(LIVE_QUOTES), abi.encodeWithSelector(QuoteRegistry.usdPrice.selector, address(0)), abi.encode(price));
    }

    /// RouterOnlyGuard.RouterOnly(): transfer rules refuse non-router pool swaps while active (claims bypass, 2026-11-12).
    bytes4 constant ROUTER_ONLY = 0xd829ca58;

    /// A direct PoolManager swap (the DirectSwapper aggregator) refused with RouterOnly (wrapped by the PoolManager).
    function _aggSwapRouterOnly(PoolKey memory key, bool zeroForOne, int256 amt) internal {
        try agg.swap(key, zeroForOne, amt) {
            revert("expected RouterOnly");
        } catch (bytes memory e) {
            assertTrue(_has(e, ROUTER_ONLY), "RouterOnly");
        }
    }

    /// A curve buyer from _graduate that holds tokens.
    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0xB0B000 + i));
    }
}

/// Several router swaps in one transaction (bots, batchers, sandwich attempts).
contract MultiSwapper {
    AvaxHookRouterV2 immutable router;

    constructor(AvaxHookRouterV2 _router) {
        router = _router;
    }

    receive() external payable {}

    function buyTwice(address token, uint256 a, uint256 b) external payable {
        router.buy{value: a}(token, a, 0, address(0), block.timestamp, "");
        router.buy{value: b}(token, b, 0, address(0), block.timestamp, "");
    }

    function buyThenSell(address token, uint256 a) external payable {
        uint256 got = router.buy{value: a}(token, a, 0, address(0), block.timestamp, "");
        IERC20(token).approve(address(router), got);
        router.sell(token, got / 2, 0, block.timestamp, "");
    }

    function sellTwice(address token, uint256 a, uint256 b) external {
        IERC20(token).approve(address(router), a + b);
        router.sell(token, a, 0, block.timestamp, "");
        router.sell(token, b, 0, block.timestamp, "");
    }
}

contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
