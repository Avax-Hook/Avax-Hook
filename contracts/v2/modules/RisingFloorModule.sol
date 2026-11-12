// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {IAvaxHookV2View} from "./HookModuleBase.sol";
import {LedgerModuleBase} from "./LedgerModuleBase.sol";

/// @title RisingFloorModule
/// @notice `bps` of every trade's quote amount (from what buyers pay, from what sellers receive; curve and
///         pool, every route) goes into a per-token treasury in the quote asset. Any holder can redeem tokens
///         against it: `redeem(token, amount, minOut)` burns `amount` (sent to 0x…dEaD) and pays
///         `amount × treasury / circulating`, where circulating = 1B − balanceOf(0x…dEaD) − the launchpad's and this
///         module's tokens. A redemption leaves `treasury / circulating` (the floor) unchanged for everyone else, and
///         every trade's fee only raises it, so the floor never falls.
///   - Redeem only after graduation. The token itself refuses wallet-to-0x…dEaD moves on the curve (transfer
///     lock), and curve holders can already sell into the curve's reserve; the treasury (separate from that
///     reserve) keeps growing from curve fees and is redeemable from the first block of the pool.
///   - The treasury is this module's claim in the hook, confirmed against the hook's books (LedgerModuleBase)
///     before it is spent; a redemption withdraws the module's claim into its own balance (`cash`) and pays
///     from there, in native AVAX or the ERC-20 quote.
///   - "Circulating" = 1B − 0x…dEaD − the launchpad's tokens − this module's own balance (it never holds
///     tokens itself; anything sent to it is out of circulation for good). Tokens in the PoolManager
///     (pool liquidity, ERC-6909 claims, tokens parked mid-unlock) always count as circulating, so nobody can
///     shrink the denominator by parking tokens there; redeem is refused while the PoolManager is unlocked.
///   - Identity-neutral: no trader reads and no transfer rule. Uses the 1B supply, so it is not for existing
///     tokens. Rounding is always in the treasury's favour.
///   - Kill switch: if the registry disables the module, fees stop but the treasury stays redeemable
///     (`rescue` has nothing to move).
contract RisingFloorModule is LedgerModuleBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Config {
        uint16 bps; // of each trade's quote amount: 0.01% .. 5%
    }

    struct Pool {
        address token;
        uint16 bps;
        bool live;
        address quote;
        uint128 treasury; // this pool's share (verified + unverified)
        uint128 unverified; // credits announced to the hook, not yet checked against its books
        uint128 redeemed; // quote paid out to redeemers
        uint128 burned; // tokens redeemed
    }

    uint16 public constant MAX_BPS = 500;

    mapping(PoolId => Pool) internal _pools;
    mapping(address => PoolId) public poolOf;
    /// @notice Quote this module holds itself (withdrawn from the hook, not yet paid), per quote asset.
    mapping(address => uint256) public cash;

    event Registered(address indexed token, PoolId id, address quote, uint16 bps);
    event Redeemed(address indexed token, address indexed holder, uint256 tokens, uint256 paid, uint256 floorPrice);

    error UnknownToken();
    error NotGraduated();
    error ZeroAmount();
    error Slippage(uint256 out);
    error SendFailed();
    error PoolManagerUnlocked();

    address internal immutable launchpad;

    constructor(address _hook) LedgerModuleBase(_hook) {
        launchpad = IAvaxHookV2View(_hook).launchpad();
    }

    receive() external payable {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.AFTER_SWAP;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.bps == 0 || c.bps > MAX_BPS) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address quote, address, bytes calldata config) external override onlyHook {
        Pool storage p = _pools[id];
        if (p.live) revert AlreadyRegistered();
        p.token = token;
        p.bps = abi.decode(config, (Config)).bps;
        p.quote = quote;
        p.live = true;
        poolOf[token] = id;
        _seed(quote);
        emit Registered(token, id, quote, p.bps);
    }

    // ---------------------------------------------------------------- accrual

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        if (!ctx.isBuy) return (0, new Credit[](0));
        return (0, _accrue(ctx.poolId, ctx.amountIn));
    }

    function onAfterSwap(SwapContext calldata ctx) external override onlyHook returns (Credit[] memory) {
        if (ctx.isBuy) return new Credit[](0);
        return _accrue(ctx.poolId, ctx.amountOut);
    }

    function _accrue(PoolId id, uint256 amount) internal returns (Credit[] memory) {
        _reconcile();
        Pool storage p = _pools[id];
        uint256 share = (amount * p.bps) / BPS;
        if (share == 0) return new Credit[](0);
        p.treasury += uint128(share);
        p.unverified += uint128(share);
        _expect(id, p.quote, share);
        return _one(address(this), share);
    }

    // ---------------------------------------------------------------- redeem

    /// @notice Burns `amount` of your tokens (approve this module first) for `amount × treasury / circulating`
    ///         of the quote, paid to you. Only after graduation.
    function redeem(address token, uint256 amount, uint256 minOut) external nonReentrant returns (uint256 out) {
        PoolId id = _poolIdOf(token);
        Pool storage p = _pools[id];
        if (!AvaxHookV2(payable(hook)).isOpen(id)) revert NotGraduated();
        if (amount == 0) revert ZeroAmount();
        if (TransientStateLibrary.isUnlocked(poolManager)) revert PoolManagerUnlocked();
        _reconcile();
        uint256 treasury = p.treasury; // all verified: no hook callback is running
        uint256 circ = _circulating(token);
        out = Math.mulDiv(amount, treasury, circ); // rounds down: the remaining holders keep the dust
        if (out == 0 || out < minOut) revert Slippage(out);
        p.treasury = uint128(treasury - out);
        p.redeemed += uint128(out);
        p.burned += uint128(amount);
        // Burn first (the token reports the move to the hook's transfer rules, if any), then pay.
        IERC20(token).safeTransferFrom(msg.sender, ModuleCaps.BURN, amount);
        _withdraw(p.quote, out);
        cash[p.quote] -= out;
        if (!_send(p.quote, msg.sender, out)) revert SendFailed();
        emit Redeemed(token, msg.sender, amount, out, _floor(p.treasury, _circulating(token)));
    }

    // ---------------------------------------------------------------- views

    /// @notice Quote units per whole token (1e18 base units) the treasury backs right now.
    function floorPrice(address token) external view returns (uint256) {
        Pool storage p = _pools[_poolIdOf(token)];
        return _floor(_confirmed(p), _circulating(token));
    }

    /// @notice What redeeming `amount` would pay now.
    function quoteRedeem(address token, uint256 amount) external view returns (uint256) {
        Pool storage p = _pools[_poolIdOf(token)];
        return Math.mulDiv(amount, _confirmed(p), _circulating(token));
    }

    /// @return quote     the treasury's asset
    /// @return bps       share of every trade
    /// @return treasury  the confirmed treasury
    /// @return pending   announced by a trade the hook has not booked (only while a trade is running)
    /// @return redeemed  quote paid to redeemers so far
    /// @return burned    tokens redeemed so far
    /// @return circulating 1B − 0x…dEaD − launchpad − this module's tokens
    function stats(address token)
        external
        view
        returns (address quote, uint16 bps, uint256 treasury, uint256 pending, uint256 redeemed, uint256 burned, uint256 circulating)
    {
        Pool storage p = _pools[_poolIdOf(token)];
        uint256 c = _confirmed(p);
        return (p.quote, p.bps, c, p.treasury - c, p.redeemed, p.burned, _circulating(token));
    }

    // ---------------------------------------------------------------- internals

    function _poolIdOf(address token) internal view returns (PoolId id) {
        id = poolOf[token];
        if (!_pools[id].live || _pools[id].token != token) revert UnknownToken();
    }

    /// @dev The treasury as the next reconcile will confirm it: the last credit counts unless the hook's books
    ///      fall short of it.
    function _confirmed(Pool storage p) internal view returns (uint256) {
        uint256 u = p.unverified;
        if (u == 0) return p.treasury;
        uint256 actual = AvaxHookV2(payable(hook)).claimable(address(this), Currency.wrap(p.quote));
        uint256 acc = accounted(p.quote);
        uint256 short = actual < acc ? acc - actual : 0;
        return p.treasury - (short > u ? u : short);
    }

    function _circulating(address token) internal view returns (uint256) {
        IERC20 t = IERC20(token);
        return TOTAL_SUPPLY - t.balanceOf(ModuleCaps.BURN) - t.balanceOf(launchpad) - t.balanceOf(address(this));
    }

    function _floor(uint256 treasury, uint256 circ) internal pure returns (uint256) {
        return circ == 0 ? 0 : Math.mulDiv(treasury, 1 ether, circ);
    }

    /// @dev Makes sure `cash[quote]` covers `amount`, withdrawing this module's whole claim from the hook.
    function _withdraw(address quote, uint256 amount) internal {
        if (cash[quote] >= amount) return;
        uint256 c = AvaxHookV2(payable(hook)).claimable(address(this), Currency.wrap(quote));
        if (c == 0) return; // the shares are backed by cash + claim; nothing left to pull
        uint256 a = accounted(quote);
        _spent(quote, c > a ? a : c);
        cash[quote] += c;
        AvaxHookV2(payable(hook)).claim(Currency.wrap(quote), address(this));
    }

    function _send(address quote, address to, uint256 amount) internal returns (bool ok) {
        if (quote == address(0)) {
            (ok,) = to.call{value: amount}("");
            return ok;
        }
        IERC20(quote).safeTransfer(to, amount);
        return true;
    }

    // LedgerModuleBase: the treasury stays redeemable even if the module is disabled.
    function _takeShare(PoolId id) internal view override returns (address, uint256) {
        return (_pools[id].quote, 0);
    }

    function _unverified(PoolId id) internal view override returns (address, uint256) {
        Pool storage p = _pools[id];
        return (p.quote, p.unverified);
    }

    function _verified(PoolId id, uint256 shortfall) internal override {
        Pool storage p = _pools[id];
        p.treasury -= uint128(shortfall); // shortfall <= unverified <= treasury
        p.unverified = 0;
    }
}
