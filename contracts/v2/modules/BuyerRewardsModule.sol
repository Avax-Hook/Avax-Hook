// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title BuyerRewardsModule
/// @notice A reward vault the creator stocks with any ERC20: every qualifying buy earns the buyer a fixed
///         reward, which they claim from this module whenever they like.
///   - Qualifying buy: a curve buy, or a pool buy through the AvaxHook router (the buyer is known), of at
///     least `minBuy` quote units, by anyone but the creator, up to `maxPerWallet` rewarded buys per wallet
///     (0 = no limit).
///   - A reward is only promised when the vault can cover it: once earned it is reserved for the buyer and
///     the creator can't take it back. When the vault runs dry, buys simply stop earning until it is topped up.
///   - Anyone may top the vault up with `fund`; only the creator may `withdraw`, and only what isn't owed.
///   - Fee-on-transfer reward tokens are booked at what actually arrived; rebasing tokens are not supported.
///   - Anti-farming: a reward stays locked for `lockSeconds` after the wallet's latest qualifying buy. If the
///     wallet sells or sends any of the token while rewards are locked, the locked rewards are forfeited back
///     to the vault (buy-and-dump loops earn nothing). Unlocked rewards are the buyer's for good.
///   - The swap and transfer callbacks never move tokens and can't fail (counters saturate), so the module
///     never blocks a trade.
contract BuyerRewardsModule is HookModuleBase, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Config {
        address rewardToken; // ERC20 paid out
        uint128 rewardPerBuy; // reward token units per qualifying buy
        uint128 minBuy; // quote units a buy must spend to qualify
        uint16 maxPerWallet; // rewarded buys per wallet, 0 = no limit
        uint32 lockSeconds; // rewards forfeit if the wallet sells/sends within this long of its latest reward
    }

    struct Vault {
        Config cfg;
        address creator;
        address token;
        uint128 balance; // reward tokens held for this pool (owed included)
        uint128 owed; // earned and not yet claimed
        uint128 totalRewarded;
        bool registered;
    }

    struct Wallet {
        uint128 owed; // unlocked, claimable
        uint128 locked; // earned, still forfeitable
        uint64 unlockAt; // when `locked` becomes `owed`
        uint16 rewardedBuys;
    }

    mapping(PoolId => Vault) internal _vaults;
    mapping(PoolId => mapping(address => Wallet)) internal _wallets;
    mapping(address => PoolId) public poolOf;

    event Funded(address indexed token, address indexed from, uint256 amount);
    event Rewarded(address indexed token, address indexed buyer, uint256 amount);
    event Claimed(address indexed token, address indexed buyer, address to, uint256 amount);
    event Withdrawn(address indexed token, address to, uint256 amount);
    event Forfeited(address indexed token, address indexed wallet, uint256 amount);

    error UnknownToken();
    error NotCreator();
    error NothingOwed();
    error MoreThanFree(uint256 free);

    constructor(address _hook) HookModuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER;
    }

    uint32 public constant MAX_LOCK = 30 days;

    function validateConfig(bytes calldata config) public view override {
        Config memory c = abi.decode(config, (Config));
        if (c.rewardToken == address(0) || c.rewardToken.code.length == 0) revert BadConfig();
        if (c.rewardPerBuy == 0 || c.minBuy == 0 || c.lockSeconds > MAX_LOCK) revert BadConfig();
    }

    function onRegister(PoolId id, address token, address, address creator, bytes calldata config) external override onlyHook {
        Vault storage v = _vaults[id];
        if (v.registered) revert AlreadyRegistered();
        v.cfg = abi.decode(config, (Config));
        v.creator = creator;
        v.token = token;
        v.registered = true;
        poolOf[token] = id;
    }

    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        address buyer = ctx.trader;
        if (ctx.isBuy && buyer != address(0)) {
            Vault storage v = _vaults[ctx.poolId];
            Config memory c = v.cfg;
            if (ctx.amountIn >= c.minBuy && buyer != v.creator && v.balance - v.owed >= c.rewardPerBuy) {
                Wallet storage w = _wallets[ctx.poolId][buyer];
                if (c.maxPerWallet == 0 || w.rewardedBuys < c.maxPerWallet) {
                    _settle(w);
                    if (w.rewardedBuys < type(uint16).max) w.rewardedBuys += 1;
                    w.locked += c.rewardPerBuy;
                    w.unlockAt = uint64(block.timestamp) + c.lockSeconds;
                    v.owed += c.rewardPerBuy;
                    unchecked {
                        // statistics only: wraps instead of reverting a buy
                        v.totalRewarded += c.rewardPerBuy;
                    }
                    emit Rewarded(v.token, buyer, c.rewardPerBuy);
                }
            }
        }
        return (0, new Credit[](0));
    }

    /// @dev Any outgoing move (a sell to the pool or curve, or a plain send) forfeits still-locked rewards.
    function onTransfer(PoolId id, address, address, address from, address, uint256 amount) external override onlyHook {
        if (amount == 0) return;
        Wallet storage w = _wallets[id][from];
        if (w.locked == 0) return;
        _settle(w);
        uint128 lost = w.locked;
        if (lost == 0) return;
        w.locked = 0;
        Vault storage v = _vaults[id];
        v.owed -= lost; // back to free balance
        emit Forfeited(v.token, from, lost);
    }

    function _settle(Wallet storage w) internal {
        if (w.locked != 0 && block.timestamp >= w.unlockAt) {
            w.owed += w.locked;
            w.locked = 0;
        }
    }

    // ---------------------------------------------------------------- vault

    /// @notice Adds reward tokens to `token`'s vault (needs an allowance). Anyone may fund.
    function fund(address token, uint256 amount) external nonReentrant {
        Vault storage v = _vault(token);
        IERC20 r = IERC20(v.cfg.rewardToken);
        uint256 before = r.balanceOf(address(this));
        r.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = r.balanceOf(address(this)) - before;
        v.balance += uint128(got);
        emit Funded(token, msg.sender, got);
    }

    /// @notice Pays out everything you earned from `token`'s buys.
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        Vault storage v = _vault(token);
        Wallet storage w = _wallets[poolOf[token]][msg.sender];
        _settle(w);
        amount = w.owed;
        if (amount == 0 || to == address(0)) revert NothingOwed();
        w.owed = 0;
        v.owed -= uint128(amount);
        v.balance -= uint128(amount);
        IERC20(v.cfg.rewardToken).safeTransfer(to, amount);
        emit Claimed(token, msg.sender, to, amount);
    }

    /// @notice The creator takes back reward tokens nobody has earned yet.
    function withdraw(address token, uint256 amount, address to) external nonReentrant {
        Vault storage v = _vault(token);
        if (msg.sender != v.creator) revert NotCreator();
        uint256 free = v.balance - v.owed;
        if (amount > free || to == address(0)) revert MoreThanFree(free);
        v.balance -= uint128(amount);
        IERC20(v.cfg.rewardToken).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ---------------------------------------------------------------- views

    /// @return rewardToken  the ERC20 paid out
    /// @return balance      held for this token's buyers (owed included)
    /// @return owed         earned, not yet claimed
    /// @return free         left to reward future buys
    /// @return rewardPerBuy reward per qualifying buy
    /// @return minBuy       quote units a buy must spend
    function vault(address token)
        external
        view
        returns (address rewardToken, uint256 balance, uint256 owed, uint256 free, uint256 rewardPerBuy, uint256 minBuy)
    {
        Vault storage v = _vaults[poolOf[token]];
        return (v.cfg.rewardToken, v.balance, v.owed, v.balance - v.owed, v.cfg.rewardPerBuy, v.cfg.minBuy);
    }

    /// @return owed         claimable now
    /// @return rewardedBuys rewarded buys so far
    /// @return locked       earned but forfeitable until `unlockAt`
    /// @return unlockAt     when `locked` becomes claimable
    function owedTo(address token, address wallet)
        external
        view
        returns (uint256 owed, uint256 rewardedBuys, uint256 locked, uint256 unlockAt)
    {
        Wallet storage w = _wallets[poolOf[token]][wallet];
        owed = w.owed;
        locked = w.locked;
        if (locked != 0 && block.timestamp >= w.unlockAt) (owed, locked) = (owed + locked, 0);
        return (owed, w.rewardedBuys, locked, w.unlockAt);
    }

    function _vault(address token) internal view returns (Vault storage v) {
        v = _vaults[poolOf[token]];
        if (!v.registered || v.token != token) revert UnknownToken();
    }
}
