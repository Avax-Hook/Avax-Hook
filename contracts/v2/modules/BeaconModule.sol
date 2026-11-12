// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase, IAvaxHookV2View, IQuotePrices} from "./HookModuleBase.sol";

/// @notice What EntangledModule reads from a beacon.
interface IBeaconModule {
    /// @return magic BeaconModule.isBeacon.selector
    function isBeacon() external pure returns (bytes4 magic);
    /// @return usd   highest recorded USD market cap of `token` (18 decimals)
    function athUsd(address token) external view returns (uint256 usd);
}

/// @title BeaconModule
/// @notice Records the token's all-time-high market cap in USD, for other tokens to react to (see
///         EntangledModule). It changes nothing about trading and takes no fees.
///   - A price only counts once it has stood into a later block: at the first swap of each block the
///     module reads the pool price BEFORE that swap (left by an earlier block) and prices it in USD through
///     the live QuoteRegistry. A same-block pump and dump never registers; a pump has to survive a block
///     boundary, open to arbitrage. If the USD price is unavailable (stale feed), nothing is recorded.
///   - A high only counts once it has been SUSTAINED: observations (first swap of a block) are grouped into
///     streaks of at least `MIN_OBSERVATIONS` distinct blocks spanning at least `HOLD_SECONDS`; the ATH can
///     only rise to the LOWEST market cap seen during such a streak. A short pump (even across a few blocks,
///     with no outside arbitrage on a young curve) never registers; to move the ATH the price has to hold.
///   - The ATH only rises. It is recorded from bonding-curve trades (curve price) and pool trades alike.
contract BeaconModule is HookModuleBase, IBeaconModule {
    struct Light {
        uint128 athUsd; // 18 decimals
        uint64 athAt;
        uint64 lastBlock; // last block with a swap
        address token;
        bool registered;
        uint128 streakMin; // lowest market cap seen in the current streak
        uint64 streakStart; // when the current streak began
        uint32 streakObs; // distinct-block observations in the current streak
    }

    uint256 public constant HOLD_SECONDS = 15 minutes;
    uint256 public constant MIN_OBSERVATIONS = 5;

    mapping(PoolId => Light) internal _lights;
    mapping(address => PoolId) public poolOf;

    event NewHigh(address indexed token, uint256 mcUsd, uint256 timestamp);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP;
    }

    /// @dev No parameters: the config must be empty.
    function validateConfig(bytes calldata config) public pure override {
        if (config.length != 0) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Light storage l = _lights[id];
        if (l.registered) revert AlreadyRegistered();
        l.token = token;
        l.registered = true;
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        Light storage l = _lights[ctx.poolId];
        if (l.lastBlock != block.number && ctx.sqrtPriceX96 != 0) {
            l.lastBlock = uint64(block.number);
            (bool ok, uint256 usd) = _tryMarketCapUsd(ctx.token, ctx.quote, ctx.sqrtPriceX96);
            if (ok) {
                if (l.streakObs == 0) {
                    (l.streakMin, l.streakStart, l.streakObs) = (uint128(usd), uint64(block.timestamp), 1);
                } else {
                    if (usd < l.streakMin) l.streakMin = uint128(usd);
                    l.streakObs += 1;
                }
                if (l.streakObs >= MIN_OBSERVATIONS && block.timestamp >= uint256(l.streakStart) + HOLD_SECONDS) {
                    uint128 held = l.streakMin;
                    if (held > l.athUsd) {
                        l.athUsd = held;
                        l.athAt = uint64(block.timestamp);
                        emit NewHigh(ctx.token, held, block.timestamp);
                    }
                    // the next streak starts at this observation
                    (l.streakMin, l.streakStart, l.streakObs) = (uint128(usd), uint64(block.timestamp), 1);
                }
            }
        }
        return (0, new Credit[](0));
    }

    function isBeacon() external pure returns (bytes4) {
        return IBeaconModule.isBeacon.selector;
    }

    function athUsd(address token) external view returns (uint256) {
        return _lights[poolOf[token]].athUsd;
    }

    /// @return usd        ATH market cap (18 decimals)
    /// @return at         when it was recorded
    /// @return registered whether `token` launched with this beacon
    function beacon(address token) external view returns (uint256 usd, uint256 at, bool registered) {
        Light storage l = _lights[poolOf[token]];
        return (l.athUsd, l.athAt, l.registered && l.token == token);
    }

    function _tryMarketCapUsd(address token, address quote, uint160 sqrtPriceX96) internal view returns (bool, uint256) {
        IQuotePrices reg = IQuotePrices(IAvaxHookV2View(hook).quoteRegistry());
        uint8 dec;
        try reg.quotes(quote) returns (bool, uint8 d, address) {
            dec = d;
        } catch {
            return (false, 0);
        }
        try reg.usdPrice(quote) returns (uint256 p) {
            uint256 usd = Math.mulDiv(_marketCapQuote(token, quote, sqrtPriceX96), p, 10 ** dec);
            return (usd <= type(uint128).max, usd);
        } catch {
            return (false, 0);
        }
    }
}
