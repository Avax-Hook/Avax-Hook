// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {IAvaxHookV2View, IQuotePrices} from "./HookModuleBase.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title PolarityModuleV2
/// @notice PolarityModule with a graduation guard on `redeem` (as RisingFloorModule has). v1 relied on the
///         curve transfer lock of HookTokenV2 to keep redeem closed during the curve; HookTokenV3 tokens move
///         freely on the curve, so v1 redeem was callable before the pool opened. v2 reverts `NotGraduated`
///         until the hook has opened that token's pool. Everything else is byte-for-byte the v1 logic.
///
/// @notice A prediction pair: two tokens (BULL and BEAR) on one price, the USD price of `asset` (any quote in
///         the live QuoteRegistry with a USD feed, e.g. AVAX, BTC.b, a stock). Each side has a pot in the trade's
///         quote; price moves shift value from the losing side's pot to the winning side's, and holders can burn
///         tokens for their pro-rata share of their side's pot at any time (a floor that rises with fees and
///         with every move the side wins).
///
///   Assets: only the immutable allowlist given at deploy (Chainlink-backed quotes), never a signed feed whose
///   signer could time its updates.
///
///   Launching: the first token (side BULL) opens a pair: (asset, side = BULL, leverageX10, feeBps, 0). The second
///   (side BEAR) completes it: (same asset, side = BEAR, same leverageX10, its own feeBps, partnerToken = the BULL
///   token). Same creator and same quote asset as the BULL launch, else the launch reverts. One BEAR per BULL.
///   Until paired, nothing rebalances: the BULL pot just grows from fees.
///
///   Fees: `feeBps` of every trade's quote (buys: from the input; sells: from the output), on the curve and in the
///   pool, router or not, goes to that token's side pot (a claim of this module in the hook).
///
///   Rebalance (O(1), on every trade of either token once paired, and on redeem/sync): with p = usdPrice(asset)
///   and pLast the price at the last rebalance,
///       r     = |p − pLast| / pLast
///       f     = min(50%, leverageX10 / 10 × r)
///       shift = f × min(potBull, potBear)   (loser = BEAR when p > pLast, BULL when p < pLast)
///   `shift` moves from the loser's pot to the winner's and pLast = p. Basing it on the SMALLER pot makes both
///   sides risk the same amount on every move: an empty or late side wins nothing it could not have lost (no
///   free option on the other side's pot). Example: leverage 2x (20), pots 10 / 4, AVAX goes $20 → $21
///   (r = 5%): f = 10%, so 0.4 moves from the BEAR pot to the BULL pot. A 25%+ move at 2x is capped at 50%.
///   The loser's pot never goes below half of what it was, and never reaches zero.
///   Skipped (pLast kept, so small moves add up) when the change is under 1 bp; skipped entirely when the feed
///   reverts or is stale (a bounded static call, never blocks a trade).
///
///   Redeem: `redeem(token, amount, minOut)` sends `amount` tokens to 0x…dEaD and pays
///   amount × sidePot / circulating, circulating = totalSupply − balances of 0x…dEaD, the launchpad and this
///   module (rounded down). Tokens in the pool (PoolManager) and the hook count as circulating: they are
///   someone's claim to be bought, and excluding them would let a holder park tokens in the PoolManager to
///   shrink `circulating` and redeem at an inflated rate (audit H-1). For the same reason redeem refuses to run
///   while the PoolManager is unlocked. So the per-token floor only changes on fees, shifts and redeems. Pays
///   native AVAX or the ERC-20 quote directly (the module pulls its claims from the hook as needed). Redeem
///   opens when that token's pool opens (checked here with `hook.isOpen`, not left to a token transfer lock);
///   the pot fills from the first curve trade.
///
///   Kill switch: there is no `rescue` (audit M): the pots belong to the holders, so after a registry disable
///   `redeem` stays the exit (no more fees or shifts; the pots stay redeemable).
///
///   Honest limits: the feed is a periodic oracle, so a trader who sees an update coming can buy the winning
///   side (or redeem the losing side) first; the pot only shifts on trades/redeems/syncs; pool prices can sit far
///   above the redeem floor; a credit the hook scales down (25% module cap) is reconciled out of the pot.
contract PolarityModuleV2 is LedgerModuleBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    struct Config {
        address asset; // price asset (a QuoteRegistry quote with a USD feed)
        uint8 side; // 0 = BULL (opens the pair), 1 = BEAR (completes it)
        uint8 leverageX10; // 10 .. 50 (1x .. 5x)
        uint16 feeBps; // 1 .. 300 (3%) of each trade's quote into the side's pot
        address partnerToken; // BEAR: the BULL token; BULL: address(0)
    }

    /// @dev Per pool (one per token).
    struct Leg {
        PoolId pair; // the BULL pool id (pair key)
        uint8 side;
        uint16 feeBps;
        bool registered;
        uint128 unverified; // credits announced to the hook, not yet checked against its books
    }

    struct Pair {
        address asset;
        uint8 leverageX10;
        bool paired;
        address quote;
        address creator;
        address bullToken;
        address bearToken;
        uint128 potBull;
        uint128 potBear;
        uint128 pLast; // 18-decimal USD price at the last rebalance (0 = none yet)
        uint64 lastRebalance;
    }

    uint8 public constant BULL = 0;
    uint8 public constant BEAR = 1;
    uint8 public constant MIN_LEV = 10;
    uint8 public constant MAX_LEV = 50;
    uint16 public constant MAX_FEE_BPS = 300;
    uint256 public constant MAX_SHIFT = 0.5e18; // 50% of the losing pot per rebalance
    uint256 internal constant PRICE_GAS = 100_000;

    uint256 public constant MAX_ASSETS = 16;

    address public immutable quoteRegistry;
    /// @notice Price assets a pair may use, fixed at deploy (Chainlink-backed QuoteRegistry quotes only).
    mapping(address asset => bool) public allowedAsset;
    address[] internal _assets;

    mapping(PoolId => Leg) internal _legs;
    mapping(PoolId bull => Pair) internal _pairs;
    mapping(address token => PoolId) public poolOf;
    /// @notice Quote assets this module holds itself (claims pulled from the hook, not paid out yet).
    mapping(address quote => uint256) public cash;

    event PairOpened(PoolId indexed pair, address indexed bullToken, address asset, uint8 leverageX10);
    event PairCompleted(PoolId indexed pair, address indexed bullToken, address indexed bearToken, uint256 price);
    event Rebalanced(PoolId indexed pair, uint256 price, uint256 lastPrice, uint8 loser, uint256 shift);
    event Redeemed(address indexed token, address indexed holder, uint256 amount, uint256 paid);

    error NotRegistered();
    error BadPartner();
    error ZeroAmount();
    error Slippage(uint256 out, uint256 minOut);
    error TransferFailed();
    error UnexpectedSender();
    error PoolManagerUnlocked();
    error NoRescue();
    error NotGraduated();

    /// @param assets the price assets pairs may use (immutable; e.g. native AVAX, USDC, USDt: the live
    ///        QuoteRegistry quotes whose feed is a Chainlink aggregator, never a signed feed).
    constructor(address _hook, address[] memory assets) LedgerModuleBase(_hook) {
        quoteRegistry = IAvaxHookV2View(_hook).quoteRegistry();
        if (assets.length == 0 || assets.length > MAX_ASSETS) revert BadConfig();
        for (uint256 i; i < assets.length; ++i) {
            if (allowedAsset[assets[i]]) revert BadConfig();
            allowedAsset[assets[i]] = true;
            _assets.push(assets[i]);
        }
    }

    /// @dev Native AVAX claims arrive from the hook (plain balances) or the PoolManager (ERC-6909 claims).
    receive() external payable {
        if (msg.sender != hook && msg.sender != address(poolManager)) revert UnexpectedSender();
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public view override {
        Config memory c = abi.decode(config, (Config));
        if (c.side > BEAR || c.leverageX10 < MIN_LEV || c.leverageX10 > MAX_LEV) revert BadConfig();
        if (c.feeBps == 0 || c.feeBps > MAX_FEE_BPS) revert BadConfig();
        if ((c.side == BULL) != (c.partnerToken == address(0))) revert BadConfig();
        if (!allowedAsset[c.asset]) revert BadConfig();
        (,, address feed) = IQuotePrices(quoteRegistry).quotes(c.asset);
        if (feed == address(0)) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config)
        external
        override
        onlyHook
    {
        Leg storage l = _legs[id];
        if (l.registered) revert AlreadyRegistered();
        validateConfig(config);
        Config memory c = abi.decode(config, (Config));
        l.side = c.side;
        l.feeBps = c.feeBps;
        l.registered = true;
        poolOf[token] = id;
        _seed(quote);

        if (c.side == BULL) {
            l.pair = id;
            Pair storage np = _pairs[id];
            np.asset = c.asset;
            np.leverageX10 = c.leverageX10;
            np.quote = quote;
            np.creator = creator;
            np.bullToken = token;
            emit PairOpened(id, token, c.asset, c.leverageX10);
            return;
        }
        PoolId bull = poolOf[c.partnerToken];
        Leg storage bl = _legs[bull];
        Pair storage p = _pairs[bull];
        if (!bl.registered || bl.side != BULL || p.paired) revert BadPartner();
        if (p.creator != creator || p.asset != c.asset || p.quote != quote || p.leverageX10 != c.leverageX10) {
            revert BadPartner();
        }
        l.pair = bull;
        p.bearToken = token;
        p.paired = true;
        (bool ok, uint256 price) = _price(c.asset);
        if (ok) {
            p.pLast = uint128(price);
            p.lastRebalance = uint64(block.timestamp);
        }
        emit PairCompleted(bull, c.partnerToken, token, price);
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _onTrade(ctx.poolId, ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _onTrade(ctx.poolId, ctx.amountOut);
    }

    /// @notice Rebalances `token`'s pair against the current feed price. Anyone.
    function sync(address token) external {
        Leg storage l = _legs[poolOf[token]];
        if (!l.registered) revert NotRegistered();
        _rebalance(l.pair);
    }

    /// @notice Burns `amount` of a side token (to 0x…dEaD) for amount × sidePot / circulating of the quote.
    ///         Needs an ERC-20 approval of `token` to this module. Rebalances first.
    function redeem(address token, uint256 amount, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (amount == 0) revert ZeroAmount();
        // H-1: no redeem in the middle of someone's PoolManager session (parked or flash-held tokens)
        if (poolManager.isUnlocked()) revert PoolManagerUnlocked();
        PoolId id = poolOf[token];
        Leg storage l = _legs[id];
        if (!l.registered) revert NotRegistered();
        // V2: redeem opens with the token's pool, not before (HookTokenV3 has no curve transfer lock).
        if (!AvaxHookV2(payable(hook)).isOpen(id)) revert NotGraduated();
        _reconcile();
        Pair storage p = _pairs[l.pair];
        _rebalance(l.pair);
        uint256 pot = l.side == BULL ? p.potBull : p.potBear;
        out = (amount * pot) / _circulating(token);
        if (out < minOut) revert Slippage(out, minOut);
        if (l.side == BULL) p.potBull = uint128(pot - out);
        else p.potBear = uint128(pot - out);
        emit Redeemed(token, msg.sender, amount, out);
        IERC20(token).safeTransferFrom(msg.sender, ModuleCaps.BURN, amount);
        if (out > 0) _pay(p.quote, msg.sender, out);
    }

    // ---------------------------------------------------------------- views

    /// @notice Everything a widget needs about `token`'s pair.
    function pairOf(address token) external view returns (Pair memory pair, uint8 side, uint16 feeBps) {
        Leg storage l = _legs[poolOf[token]];
        return (_pairs[l.pair], l.side, l.feeBps);
    }

    /// @notice Pots if the pair were rebalanced now (what redeem would use), and the feed price (0 if unavailable).
    function previewPots(address token) public view returns (uint256 potBull, uint256 potBear, uint256 price) {
        Leg storage l = _legs[poolOf[token]];
        Pair storage p = _pairs[l.pair];
        (potBull, potBear) = (p.potBull, p.potBear);
        bool ok;
        (ok, price) = _price(p.asset);
        if (!ok) return (potBull, potBear, 0);
        if (!p.paired || p.pLast == 0) return (potBull, potBear, price);
        (uint8 loser, uint256 shift) = _shiftFor(p, price);
        if (shift == 0) return (potBull, potBear, price);
        if (loser == BEAR) (potBull, potBear) = (potBull + shift, potBear - shift);
        else (potBull, potBear) = (potBull - shift, potBear + shift);
    }

    /// @notice What redeeming `amount` of `token` pays now (before slippage).
    function previewRedeem(address token, uint256 amount) external view returns (uint256) {
        Leg storage l = _legs[poolOf[token]];
        if (!l.registered) return 0;
        (uint256 b, uint256 s,) = previewPots(token);
        return (amount * (l.side == BULL ? b : s)) / _circulating(token);
    }

    /// @notice The price assets pairs may use.
    function assets() external view returns (address[] memory) {
        return _assets;
    }

    /// @notice Tokens that hold a claim on the side pot.
    function circulating(address token) external view returns (uint256) {
        return _circulating(token);
    }

    // ---------------------------------------------------------------- internals

    function _onTrade(PoolId id, uint256 amount) internal returns (Credit[] memory) {
        _reconcile();
        Leg storage l = _legs[id];
        _rebalance(l.pair);
        uint256 fee = (amount * l.feeBps) / BPS;
        if (fee == 0) return new Credit[](0);
        Pair storage p = _pairs[l.pair];
        if (l.side == BULL) p.potBull += uint128(fee);
        else p.potBear += uint128(fee);
        l.unverified += uint128(fee);
        _expect(id, p.quote, fee);
        return _one(address(this), fee);
    }

    function _rebalance(PoolId pairId) internal {
        Pair storage p = _pairs[pairId];
        if (!p.paired) return;
        (bool ok, uint256 price) = _price(p.asset);
        if (!ok) return;
        uint256 last = p.pLast;
        if (last == 0) {
            p.pLast = uint128(price);
            p.lastRebalance = uint64(block.timestamp);
            return;
        }
        uint256 diff = price > last ? price - last : last - price;
        if (diff * BPS < last) return; // under 1 bp: keep pLast so small moves add up
        (uint8 loser, uint256 shift) = _shiftFor(p, price);
        if (shift > 0) {
            if (loser == BEAR) (p.potBear, p.potBull) = (p.potBear - uint128(shift), p.potBull + uint128(shift));
            else (p.potBull, p.potBear) = (p.potBull - uint128(shift), p.potBear + uint128(shift));
        }
        p.pLast = uint128(price);
        p.lastRebalance = uint64(block.timestamp);
        emit Rebalanced(pairId, price, last, loser, shift);
    }

    /// @dev shift = min(potBull, potBear) × min(50%, lev/10 × |p − pLast| / pLast); 0 under 1 bp.
    function _shiftFor(Pair storage p, uint256 price) internal view returns (uint8 loser, uint256 shift) {
        uint256 last = p.pLast;
        uint256 diff = price > last ? price - last : last - price;
        if (last == 0 || diff * BPS < last) return (0, 0);
        loser = price > last ? BEAR : BULL;
        uint256 f = (uint256(p.leverageX10) * diff * 1e17) / last; // lev/10 × r, 1e18 = 100%
        if (f > MAX_SHIFT) f = MAX_SHIFT;
        uint256 pot = p.potBear < p.potBull ? p.potBear : p.potBull; // both sides risk the same
        shift = (pot * f) / 1e18;
    }

    /// @dev The feed price through a bounded static call; (false, 0) on any revert or malformed answer.
    function _price(address asset) internal view returns (bool ok, uint256 price) {
        bytes memory ret;
        (ok, ret) = quoteRegistry.staticcall{gas: PRICE_GAS}(abi.encodeCall(IQuotePrices.usdPrice, (asset)));
        if (!ok || ret.length != 32) return (false, 0);
        price = abi.decode(ret, (uint256));
        if (price == 0 || price > type(uint128).max) return (false, 0);
    }

    function _circulating(address token) internal view returns (uint256 c) {
        IERC20 t = IERC20(token);
        c = t.totalSupply() - t.balanceOf(ModuleCaps.BURN) - t.balanceOf(IAvaxHookV2View(hook).launchpad())
            - t.balanceOf(address(this));
        if (c == 0) c = 1;
    }

    /// @dev Pays `amount` of `quote` out of this module's funds: cash first, pulling every claim from the hook
    ///      when cash is short.
    function _pay(address quote, address to, uint256 amount) internal {
        uint256 have = cash[quote];
        if (have < amount) {
            uint256 c = AvaxHookV2(payable(hook)).claimable(address(this), Currency.wrap(quote));
            if (c > 0) {
                uint256 acc = accounted(quote);
                _spent(quote, c < acc ? c : acc);
                have += c;
                AvaxHookV2(payable(hook)).claim(Currency.wrap(quote), address(this));
            }
        }
        cash[quote] = have - amount;
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    /// @notice Disabled on purpose (audit M): the pots are the holders' redeem floor, not the creator's. After a
    ///         registry disable, holders keep redeeming; nothing is stranded.
    function rescue(address) external pure override {
        revert NoRescue();
    }

    function _takeShare(PoolId id) internal override returns (address quote, uint256 amount) {
        Leg storage l = _legs[id];
        Pair storage p = _pairs[l.pair];
        quote = p.quote;
        if (l.side == BULL) (amount, p.potBull) = (p.potBull, 0);
        else (amount, p.potBear) = (p.potBear, 0);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Leg storage l = _legs[id];
        return (_pairs[l.pair].quote, l.unverified);
    }

    /// @dev A shortfall comes out of the leg's own pot first, then the other side's (shifts may have moved it).
    function _verified(PoolId id, uint256 shortfall) internal override {
        Leg storage l = _legs[id];
        l.unverified = 0;
        if (shortfall == 0) return;
        Pair storage p = _pairs[l.pair];
        uint256 own = l.side == BULL ? p.potBull : p.potBear;
        uint256 a = shortfall > own ? own : shortfall;
        uint256 rest = shortfall - a;
        if (l.side == BULL) {
            p.potBull = uint128(own - a);
            p.potBear = rest > p.potBear ? 0 : p.potBear - uint128(rest);
        } else {
            p.potBear = uint128(own - a);
            p.potBull = rest > p.potBull ? 0 : p.potBull - uint128(rest);
        }
    }
}
