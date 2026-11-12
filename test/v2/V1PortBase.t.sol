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
import {AntiSnipeModule} from "../../contracts/v2/modules/AntiSnipeModule.sol";
import {WhaleGuardModule} from "../../contracts/v2/modules/WhaleGuardModule.sol";
import {DumpGuardModule} from "../../contracts/v2/modules/DumpGuardModule.sol";
import {MevShieldModule} from "../../contracts/v2/modules/MevShieldModule.sol";
import {SellTaxDecayModule} from "../../contracts/v2/modules/SellTaxDecayModule.sol";
import {DynamicFeeModule} from "../../contracts/v2/modules/DynamicFeeModule.sol";
import {VolatilityFeeModule} from "../../contracts/v2/modules/VolatilityFeeModule.sol";
import {ReferralModule} from "../../contracts/v2/modules/ReferralModule.sol";
import {AutoBurnModule} from "../../contracts/v2/modules/AutoBurnModule.sol";
import {BuybackModule} from "../../contracts/v2/modules/BuybackModule.sol";
import {LpRewardsModule} from "../../contracts/v2/modules/LpRewardsModule.sol";
import {NthBuyPotModule} from "../../contracts/v2/modules/NthBuyPotModule.sol";
import {LastBuyerPotModule} from "../../contracts/v2/modules/LastBuyerPotModule.sol";
import {V2Base} from "./V2Base.t.sol";

/// The 13 v1 blocks ported to v2 modules, registered on top of V2Base (fork, live QuoteRegistry).
/// Note: forge runs a whole test function as ONE transaction, so the hook's per-transaction volume
/// (ctx.txVolume, transient storage) keeps adding up across a test, per pool and side.
abstract contract V1PortBase is V2Base {
    AntiSnipeModule antiSnipe;
    WhaleGuardModule whale;
    DumpGuardModule dump;
    MevShieldModule mev;
    SellTaxDecayModule sellTax;
    DynamicFeeModule surge;
    VolatilityFeeModule vol;
    ReferralModule referral;
    AutoBurnModule burn;
    BuybackModule buyback;
    LpRewardsModule lpRewards;
    NthBuyPotModule nthPot;
    LastBuyerPotModule timerPot;

    uint32 antiSnipeId;
    uint32 whaleId;
    uint32 dumpId;
    uint32 mevId;
    uint32 sellTaxId;
    uint32 surgeId;
    uint32 volId;
    uint32 referralId;
    uint32 burnId;
    uint32 buybackId;
    uint32 lpId;
    uint32 nthPotId;
    uint32 timerPotId;

    address keeperBot = makeAddr("keeper");

    function setUp() public virtual override {
        super.setUp();
        address h = address(hook);
        antiSnipe = new AntiSnipeModule(h);
        whale = new WhaleGuardModule(h);
        dump = new DumpGuardModule(h);
        mev = new MevShieldModule(h);
        sellTax = new SellTaxDecayModule(h);
        surge = new DynamicFeeModule(h);
        vol = new VolatilityFeeModule(h);
        referral = new ReferralModule(h);
        burn = new AutoBurnModule(h);
        buyback = new BuybackModule(h);
        lpRewards = new LpRewardsModule(h);
        nthPot = new NthBuyPotModule(h);
        timerPot = new LastBuyerPotModule(h);
        antiSnipeId = modules.addModule(address(antiSnipe), '{"name":"Anti-snipe"}');
        whaleId = modules.addModule(address(whale), '{"name":"Whale guard"}');
        dumpId = modules.addModule(address(dump), '{"name":"Dump guard"}');
        mevId = modules.addModule(address(mev), '{"name":"MEV shield"}');
        sellTaxId = modules.addModule(address(sellTax), '{"name":"Sell tax decay"}');
        surgeId = modules.addModule(address(surge), '{"name":"Dynamic fee"}');
        volId = modules.addModule(address(vol), '{"name":"Volatility fee"}');
        referralId = modules.addModule(address(referral), '{"name":"Referral"}');
        burnId = modules.addModule(address(burn), '{"name":"Auto burn"}');
        buybackId = modules.addModule(address(buyback), '{"name":"Buyback"}');
        lpId = modules.addModule(address(lpRewards), '{"name":"LP rewards"}');
        nthPotId = modules.addModule(address(nthPot), '{"name":"Nth-buy pot"}');
        timerPotId = modules.addModule(address(timerPot), '{"name":"Last-buyer pot"}');
        buyback.setKeeper(keeperBot);
    }

    // ---------------------------------------------------------------- configs

    function _antiSnipeCfg(uint32 blocks, uint96 perBlock, uint16 taxBps) internal pure returns (bytes memory) {
        return abi.encode(AntiSnipeModule.Config(blocks, perBlock, taxBps));
    }

    function _whaleCfg(uint32 blocks, uint96 maxBuy) internal pure returns (bytes memory) {
        return abi.encode(WhaleGuardModule.Config(blocks, maxBuy));
    }

    function _dumpCfg(uint32 blocks, uint16 maxSellBps) internal pure returns (bytes memory) {
        return abi.encode(DumpGuardModule.Config(blocks, maxSellBps));
    }

    function _mevCfg(uint32 blocks, uint64 maxPriority) internal pure returns (bytes memory) {
        return abi.encode(MevShieldModule.Config(blocks, maxPriority));
    }

    function _sellTaxCfg(uint32 blocks, uint24 pips) internal pure returns (bytes memory) {
        return abi.encode(SellTaxDecayModule.Config(blocks, pips));
    }

    function _surgeCfg(uint24 maxFee, uint8 sens) internal pure returns (bytes memory) {
        return abi.encode(DynamicFeeModule.Config(maxFee, sens));
    }

    function _volCfg(uint16 perTick, uint24 maxPips) internal pure returns (bytes memory) {
        return abi.encode(VolatilityFeeModule.Config(perTick, maxPips));
    }

    function _referralCfg(uint16 feeBps, uint16 refBps) internal pure returns (bytes memory) {
        return abi.encode(ReferralModule.Config(feeBps, refBps));
    }

    function _burnCfg(uint16 bps) internal pure returns (bytes memory) {
        return abi.encode(AutoBurnModule.Config(bps));
    }

    function _buybackCfg(uint16 bps, uint96 maxSpend) internal pure returns (bytes memory) {
        return abi.encode(BuybackModule.Config(bps, maxSpend));
    }

    function _lpCfg(uint16 bps) internal pure returns (bytes memory) {
        return abi.encode(LpRewardsModule.Config(bps));
    }

    function _nthCfg(uint16 bps, uint32 everyN, uint96 minBuy) internal pure returns (bytes memory) {
        return abi.encode(NthBuyPotModule.Config(bps, everyN, minBuy));
    }

    function _timerCfg(uint16 bps, uint32 secs, uint96 minBuy) internal pure returns (bytes memory) {
        return abi.encode(LastBuyerPotModule.Config(bps, secs, minBuy));
    }

    // ---------------------------------------------------------------- launch helpers

    function _ids1(uint32 a) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](1);
        ids[0] = a;
    }

    function _cfgs1(bytes memory a) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = a;
    }

    function _ids2(uint32 a, uint32 b) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _cfgs2(bytes memory a, bytes memory b) internal pure returns (bytes[] memory c) {
        c = new bytes[](2);
        (c[0], c[1]) = (a, b);
    }

    /// Window rules also run for their first blocks after the launch on the curve (phase-aware modules);
    /// the pool tests let those curve windows pass before graduating with big curve buys.
    uint256 constant CURVE_WINDOWS = 43_201;

    /// Launches with one module and graduates (core: 1% creator fee, 0.3% base LP fee).
    function _one(uint32 id, bytes memory cfg) internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(_ids1(id), _cfgs1(cfg), 100);
        vm.roll(vm.getBlockNumber() + CURVE_WINDOWS);
        key = _graduate(t);
    }

    function _many(uint32[] memory ids, bytes[] memory cfgs, uint16 creatorFeeBps)
        internal
        returns (HookTokenV2 t, PoolKey memory key)
    {
        t = _launch(ids, cfgs, creatorFeeBps);
        vm.roll(vm.getBlockNumber() + CURVE_WINDOWS);
        key = _graduate(t);
    }

    function _plain() internal returns (HookTokenV2 t, PoolKey memory key) {
        t = _launch(new uint32[](0), new bytes[](0), 100);
        key = _graduate(t);
    }

    function _routerBuyRef(address who, HookTokenV2 t, uint256 amt, address ref) internal returns (uint256 out) {
        vm.prank(who);
        out = router.buy{value: amt}(address(t), amt, 0, ref, block.timestamp, "");
    }

    /// Native AVAX is always currency0, so a buy is zeroForOne.
    function _directBuy(PoolKey memory key, uint256 amt) internal {
        agg.swap(key, true, -int256(amt));
    }
}

/// Several router swaps in ONE transaction (the HK-4 split-trade PoC).
contract MultiTrader {
    IRouterV2 immutable r;

    constructor(address _r) {
        r = IRouterV2(_r);
    }

    receive() external payable {}

    function buys(address token, uint256 each, uint256 n) external {
        for (uint256 i; i < n; ++i) {
            r.buy{value: each}(token, each, 0, address(0), block.timestamp, "");
        }
    }

    function sells(address token, uint256 each, uint256 n) external {
        IERC20(token).approve(address(r), type(uint256).max);
        for (uint256 i; i < n; ++i) {
            r.sell(token, each, 0, block.timestamp, "");
        }
    }
}

interface IRouterV2 {
    function buy(address, uint256, uint256, address, uint256, bytes calldata) external payable returns (uint256);
    function sell(address, uint256, uint256, uint256, bytes calldata) external returns (uint256);
}

/// Calls the PoolManager directly and passes router-shaped hookData naming someone else as the trader (the
/// HK-3 pot-spoofing PoC). The hook only trusts hookData from its bound router, so this names nobody.
contract SpoofSwapper is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function buyAs(PoolKey calldata key, uint256 amt, address victim, address referrer) external {
        pm.unlock(abi.encode(key, amt, abi.encode(victim, referrer, bytes(""))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amt, bytes memory hookData) = abi.decode(data, (PoolKey, uint256, bytes));
        pm.swap(key, SwapParams(true, -int256(amt), TickMath.MIN_SQRT_PRICE + 1), hookData);
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        if (d1 > 0) pm.take(key.currency1, address(this), uint256(d1));
        return "";
    }
}

/// Same-block pump / dump helper for the buyback sandwich PoC.
contract Sandwicher is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    receive() external payable {}

    function swap(PoolKey calldata key, bool buy, uint256 amt) external {
        pm.unlock(abi.encode(key, buy, amt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool buy, uint256 amt) = abi.decode(data, (PoolKey, bool, uint256));
        pm.swap(key, SwapParams(buy, -int256(amt), buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        if (d0 > 0) pm.take(key.currency0, address(this), uint256(d0));
        if (d1 < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(-d1));
            pm.settle();
        }
        if (d1 > 0) pm.take(key.currency1, address(this), uint256(d1));
        return "";
    }
}
