// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {AvaxHookV2} from "../AvaxHookV2.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";

interface IPositionManagerLite {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

/// @title PoolCoordinatorV1
/// @notice Opens AvaxHook pools for tokens that already exist (no bonding curve, no new token). It is bound
///         as the "launchpad" of a second AvaxHookV2 instance (same code as the launch hook, its own module
///         registry), so the hook's rules hold unchanged: 0.3% protocol fee, a creator fee, a base LP fee,
///         up to 8 modules frozen at creation, exact-input and full-fill swaps, full-range liquidity only.
///
///   - Permissionless: anyone opens a pool for any token against an allowed quote and becomes its creator
///     (creator fee capped at 1% and base LP fee at 1% here, audit L-3). An AVAX open fee goes to the
///     protocol recipient. The Safe can mark pools verified (opened by or for the token's team) for the UI.
///   - Several pools per currency pair are possible (different rules); each gets the next tick spacing
///     (60, 61, ...) because the rest of the v4 pool key is fixed. The counter is per sorted pair, so
///     JOE-priced-in-USDC and USDC-priced-in-JOE share it. The open fee grows with that count (audit L-2):
///     `openFeeFor` = openFee * (1 + n / OPEN_FEE_STEP) for the pair's n-th pool (0-based), so the first 10
///     pools of a pair cost 1x, the next 10 2x, ... and the 1,000th 100x. At 0.5 AVAX, filling a pair up to
///     MAX_POOLS_PER_PAIR costs about 25,000 AVAX (squatting is uneconomic, not impossible).
///   - Modules that need the token's transfer callback (ON_TRANSFER) can't work on a token we did not
///     deploy and are refused.
///   - Required seed (audit L-4): the opener adds the first full-range position in the same transaction,
///     minted through Uniswap's PositionManager as an ordinary NFT owned by the opener (removable like any
///     other position). Both legs must be non-zero and give at least MIN_SEED_LIQUIDITY, so no pool opens
///     empty at a price anyone could push for free. (If every LP leaves later, the pools hook refuses swaps
///     that don't fill completely, so an empty pool's price can't be moved either.)
///   - Deployed paused (audit I-5): the owner reopens it with setConfig once the profile is wired up.
///
///   The coordinator never holds pool liquidity and never adds liquidity as itself (the hook lets its
///   launchpad skip the liquidity rules, so it must not): the seed goes through the PositionManager.
contract PoolCoordinatorV1 is Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct OpenArgs {
        address token; // the asset being priced
        address quote; // address(0) = native AVAX; must be allowed
        AvaxHookV2.CoreConfig core;
        uint32[] moduleIds; // ids in this profile's module registry
        bytes[] moduleConfigs;
        uint160 sqrtPriceX96; // opening price in pool orientation (currency1 per currency0)
        uint256 seedToken; // optional first position: token amount (0 with seedQuote 0 = no seed)
        uint256 seedQuote; // quote amount (AVAX: sent as value on top of the open fee)
    }

    struct PoolRecord {
        address token;
        address quote;
        address creator;
        int24 tickSpacing;
        uint48 openedAt;
        bool verified;
    }

    uint16 public constant MAX_CREATOR_FEE_BPS = 100; // 1%
    /// @notice Base LP fee cap in this profile (pips, 1e6 = 100%): 1%. The hook itself allows 10%.
    uint24 public constant MAX_BASE_FEE_PIPS = 10_000;
    /// @notice The open fee steps up by one `openFee` every OPEN_FEE_STEP pools of a pair (see openFeeFor).
    uint256 public constant OPEN_FEE_STEP = 10;
    /// @notice Smallest seed position (v4 liquidity units): a dust guard.
    uint128 public constant MIN_SEED_LIQUIDITY = 1e6;
    int24 public constant BASE_TICK_SPACING = 60;
    uint256 public constant MAX_POOLS_PER_PAIR = 1_000;
    uint96 public constant MAX_OPEN_FEE = 10 ether;

    IPoolManager public immutable poolManager;
    AvaxHookV2 public immutable hook;
    IPositionManagerLite public immutable positionManager;
    IAllowanceTransfer public immutable permit2;

    /// @notice Receives open fees, and the hook's protocol fee (AvaxHookV2.claimProtocol reads it here).
    address public protocolRecipient;
    /// @notice Base open fee (wei); what a pair's next pool costs is `openFeeFor(token, quote)`.
    uint96 public openFee;
    bool public paused;
    /// @notice Open fees collected and not yet sent to the protocol recipient.
    uint256 public feesOwed;

    mapping(address quote => bool) public quoteAllowed;
    mapping(PoolId => PoolRecord) internal _records;
    mapping(address token => mapping(address quote => PoolId[])) internal _pairPools;
    /// @dev Pools per sorted (currency0, currency1): the next pool's tick spacing offset.
    mapping(address c0 => mapping(address c1 => uint256)) internal _sortedCount;
    mapping(address token => PoolId[]) internal _tokenPools;
    mapping(address creator => PoolId[]) internal _creatorPools;
    PoolId[] internal _all;

    event PoolOpened(
        PoolId indexed id,
        address indexed token,
        address indexed quote,
        address creator,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint256 seedTokenId
    );
    event Verified(PoolId indexed id, bool verified);
    event QuoteAllowed(address indexed quote, bool allowed);
    event ConfigUpdated(address protocolRecipient, uint96 openFee, bool paused);
    event FeesSent(address indexed to, uint256 amount);
    event Rescued(address indexed asset, address indexed to, uint256 amount);

    error Paused();
    error BadArgs();
    error BadValue();
    error QuoteNotAllowed();
    error NotAToken();
    error CreatorFeeTooHigh();
    error BaseFeeTooHigh();
    error SeedRequired();
    error TransferModuleNotAllowed();
    error PairFull();
    error UnknownPool();
    error TransferFailed();

    constructor(
        IPoolManager _poolManager,
        AvaxHookV2 _hook,
        IPositionManagerLite _positionManager,
        IAllowanceTransfer _permit2,
        address _owner,
        address _protocolRecipient,
        uint96 _openFee
    ) Ownable(_owner) {
        if (_protocolRecipient == address(0) || _openFee > MAX_OPEN_FEE) revert BadArgs();
        poolManager = _poolManager;
        hook = _hook;
        positionManager = _positionManager;
        permit2 = _permit2;
        protocolRecipient = _protocolRecipient;
        openFee = _openFee;
        paused = true; // reopened by the owner once modules and quotes are configured
        quoteAllowed[address(0)] = true;
        emit QuoteAllowed(address(0), true);
        emit ConfigUpdated(_protocolRecipient, _openFee, true);
    }

    /// @dev Native refunds from the PositionManager's sweep.
    receive() external payable {
        if (msg.sender != address(positionManager)) revert BadValue();
    }

    // ---------------------------------------------------------------- admin

    function setConfig(address _protocolRecipient, uint96 _openFee, bool _paused) external onlyOwner {
        if (_protocolRecipient == address(0) || _openFee > MAX_OPEN_FEE) revert BadArgs();
        protocolRecipient = _protocolRecipient;
        openFee = _openFee;
        paused = _paused;
        emit ConfigUpdated(_protocolRecipient, _openFee, _paused);
    }

    function setQuote(address quote, bool allowed) external onlyOwner {
        if (quote != address(0) && quote.code.length == 0) revert NotAToken();
        quoteAllowed[quote] = allowed;
        emit QuoteAllowed(quote, allowed);
    }

    /// @notice UI badge only (opened by or for the token's team); it changes nothing on chain.
    function setVerified(PoolId id, bool verified) external onlyOwner {
        if (_records[id].token == address(0)) revert UnknownPool();
        _records[id].verified = verified;
        emit Verified(id, verified);
    }

    /// @notice Sends the collected open fees to the protocol recipient. Permissionless.
    function sendFees() external nonReentrant {
        uint256 amount = feesOwed;
        if (amount == 0) revert BadValue();
        feesOwed = 0;
        address to = protocolRecipient;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit FeesSent(to, amount);
    }

    /// @notice Returns assets sent here by mistake (never the open fees owed to the protocol).
    function rescue(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert BadArgs();
        if (asset == address(0)) {
            if (amount > address(this).balance - feesOwed) revert BadValue();
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        emit Rescued(asset, to, amount);
    }

    // ---------------------------------------------------------------- open

    /// @notice Opens a new hooked pool for an existing token. Value: `openFeeFor(token, quote)`, plus
    ///         `seedQuote` for a native-AVAX seed. ERC-20 seed legs are pulled from the caller (approve this
    ///         contract first). Both seed legs are required.
    /// @return id the new pool
    /// @return seedTokenId the opener's PositionManager NFT
    function openPool(OpenArgs calldata a) external payable nonReentrant returns (PoolId id, uint256 seedTokenId) {
        if (paused) revert Paused();
        if (!quoteAllowed[a.quote]) revert QuoteNotAllowed();
        if (a.token == a.quote || a.token == address(0) || a.token.code.length == 0) revert NotAToken();
        // A real ERC-20 (decimals and supply readable); anything else can't be priced or listed.
        IERC20Metadata(a.token).decimals();
        if (IERC20(a.token).totalSupply() == 0) revert NotAToken();
        if (a.core.creatorFeeBps > MAX_CREATOR_FEE_BPS) revert CreatorFeeTooHigh();
        if (a.core.baseFeePips > MAX_BASE_FEE_PIPS) revert BaseFeeTooHigh();
        if (a.seedToken == 0 || a.seedQuote == 0) revert SeedRequired();
        (address c0, address c1) = _sort(a.token, a.quote);
        uint256 n = _sortedCount[c0][c1];
        if (n >= MAX_POOLS_PER_PAIR) revert PairFull();
        bool native = a.quote == address(0);
        uint256 fee = _feeAt(n);
        if (msg.value != fee + (native ? a.seedQuote : 0)) revert BadValue();
        feesOwed += fee;

        _sortedCount[c0][c1] = n + 1;
        PoolKey memory key = _key(a.token, a.quote, BASE_TICK_SPACING + int24(int256(n)));
        id = key.toId();

        uint16 caps = hook.registerPool(key, a.token, msg.sender, a.core, a.moduleIds, a.moduleConfigs);
        if (caps & ModuleCaps.ON_TRANSFER != 0) revert TransferModuleNotAllowed();
        poolManager.initialize(key, a.sqrtPriceX96); // the hook checks the caller and marks the pool open

        _records[id] = PoolRecord({
            token: a.token,
            quote: a.quote,
            creator: msg.sender,
            tickSpacing: key.tickSpacing,
            openedAt: uint48(block.timestamp),
            verified: false
        });
        _pairPools[a.token][a.quote].push(id);
        _tokenPools[a.token].push(id);
        _creatorPools[msg.sender].push(id);
        _all.push(id);

        seedTokenId = _seed(key, a);
        emit PoolOpened(id, a.token, a.quote, msg.sender, key.tickSpacing, a.sqrtPriceX96, seedTokenId);
    }

    /// @dev Mints the opener's first full-range position through the PositionManager (so the hook's
    ///      liquidity rules apply as for anyone) and returns what it did not use.
    function _seed(PoolKey memory key, OpenArgs calldata a) internal returns (uint256 tokenId) {
        bool native = a.quote == address(0);
        // Refunds are what this seed left over, never balances that were here before (stray transfers).
        uint256 tokenBase = IERC20(a.token).balanceOf(address(this));
        uint256 quoteBase = native ? address(this).balance - a.seedQuote : IERC20(a.quote).balanceOf(address(this));
        uint256 tokenIn = _pullExact(a.token, a.seedToken);
        uint256 quoteIn = native ? a.seedQuote : _pullExact(a.quote, a.seedQuote);

        bool tokenIs0 = Currency.unwrap(key.currency0) == a.token;
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (tokenIn, quoteIn) : (quoteIn, tokenIn);
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            a.sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        if (liquidity < MIN_SEED_LIQUIDITY) revert SeedRequired();

        _approvePermit2(a.token, tokenIn);
        if (!native) _approvePermit2(a.quote, quoteIn);

        bytes memory actions = native
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] = abi.encode(key, lower, upper, uint256(liquidity), uint128(amount0), uint128(amount1), msg.sender, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        if (native) params[2] = abi.encode(Currency.wrap(address(0)), address(this));

        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities{value: native ? quoteIn : 0}(abi.encode(actions, params), block.timestamp);

        // Return what the position did not take (the ratio rarely matches both amounts exactly).
        _refund(a.token, tokenBase, msg.sender);
        _refund(a.quote, quoteBase, msg.sender);
    }

    /// @dev Pulls `amount` and returns what arrived; fee-on-transfer tokens deliver less and are refused
    ///      (v4 pools can't account for them).
    function _pullExact(address token, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert NotAToken();
        return amount;
    }

    function _approvePermit2(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(permit2), amount);
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp));
    }

    /// @dev Sends `to` what this contract holds of `asset` above `base` (the balance before the seed).
    function _refund(address asset, uint256 base, address to) internal {
        if (asset == address(0)) {
            uint256 bal = address(this).balance;
            if (bal <= base) return;
            (bool ok,) = to.call{value: bal - base}("");
            if (!ok) revert TransferFailed();
        } else {
            uint256 bal = IERC20(asset).balanceOf(address(this));
            if (bal > base) IERC20(asset).safeTransfer(to, bal - base);
            IERC20(asset).forceApprove(address(permit2), 0);
        }
    }

    // ---------------------------------------------------------------- views

    function poolKeyOf(PoolId id) public view returns (PoolKey memory) {
        PoolRecord storage r = _records[id];
        if (r.token == address(0)) revert UnknownPool();
        return _key(r.token, r.quote, r.tickSpacing);
    }

    /// @notice What opening the next pool for this pair costs (wei, without the seed), in either orientation:
    ///         openFee * (1 + pairCount / OPEN_FEE_STEP).
    function openFeeFor(address token, address quote) external view returns (uint256) {
        (address c0, address c1) = _sort(token, quote);
        return _feeAt(_sortedCount[c0][c1]);
    }

    function _feeAt(uint256 n) internal view returns (uint256) {
        return uint256(openFee) * (1 + n / OPEN_FEE_STEP);
    }

    /// @notice The key the next pool for this pair would get.
    function nextPoolKey(address token, address quote) external view returns (PoolKey memory) {
        (address c0, address c1) = _sort(token, quote);
        return _key(token, quote, BASE_TICK_SPACING + int24(int256(_sortedCount[c0][c1])));
    }

    /// @notice Pools opened on this currency pair in either orientation.
    function pairCount(address token, address quote) external view returns (uint256) {
        (address c0, address c1) = _sort(token, quote);
        return _sortedCount[c0][c1];
    }

    function record(PoolId id) external view returns (PoolRecord memory) {
        return _records[id];
    }

    function poolsOfPair(address token, address quote) external view returns (PoolId[] memory) {
        return _pairPools[token][quote];
    }

    function poolsOfToken(address token) external view returns (PoolId[] memory) {
        return _tokenPools[token];
    }

    function poolsOfCreator(address creator) external view returns (PoolId[] memory) {
        return _creatorPools[creator];
    }

    function poolCount() external view returns (uint256) {
        return _all.length;
    }

    /// @notice Newest-first page of every pool.
    function poolsPage(uint256 offset, uint256 limit) external view returns (PoolId[] memory ids, PoolRecord[] memory recs) {
        uint256 n = _all.length;
        if (offset >= n) return (ids, recs);
        uint256 count = n - offset < limit ? n - offset : limit;
        ids = new PoolId[](count);
        recs = new PoolRecord[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _all[n - 1 - offset - i];
            recs[i] = _records[ids[i]];
        }
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return uint160(a) < uint160(b) ? (a, b) : (b, a);
    }

    function _key(address token, address quote, int24 spacing) internal view returns (PoolKey memory key) {
        (address c0, address c1) = _sort(token, quote);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }
}
