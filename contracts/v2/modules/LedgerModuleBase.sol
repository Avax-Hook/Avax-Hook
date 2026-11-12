// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {AvaxHookV2} from "../AvaxHookV2.sol";
import {HookModuleBase} from "./HookModuleBase.sol";

/// @title LedgerModuleBase
/// @notice For modules that credit themselves in the hook and pay out later (pots, buyback savings). A module
///         is a singleton: its claimable balance per quote currency in AvaxHookV2 is shared by every pool it
///         serves, so it keeps per-pool shares and must never count a credit the hook didn't book, or one
///         pool's payout would spend another pool's money.
///
///         The hook books a swap callback's credits only after every module of the pool has run, and may
///         scale them down (when together they ask for more than the 25% module cut cap) or drop them (a
///         failed isolated sell-path call). So every credit a module counts is *unverified*: the pool keeps
///         it next to its share and the module remembers the pool. The next time the module acts outside
///         that same callback it compares its real claimable balance with what it counted and takes any
///         shortfall back from that pool. Inside the callback (AvaxHookV2.dispatchId unchanged) nothing is
///         booked yet: credits announced there add up and are never paid out before they are verified.
///
///         Kill switch (L-2): once the registry disables the module, `rescue` (anyone) pays each pool's
///         remaining share to that pool's creator, so funds can't strand in a module the hook no longer calls.
abstract contract LedgerModuleBase is HookModuleBase {
    /// @dev quote => 1 + the claimable balance this module counts on holding in the hook (sum of pool
    ///      shares). Seeded to 1 at registration so a credit inside a gas-capped callback never pays for a
    ///      fresh storage slot.
    mapping(address => uint256) internal _acc;
    /// @dev The pool holding the one unverified credit (never cleared, only its amount is; seeded non-zero).
    PoolId internal _pendingPool = PoolId.wrap(bytes32(uint256(1)));

    /// @dev Transient: AvaxHookV2.dispatchId() when this module last announced a credit.
    bytes32 internal constant _MARK = keccak256("avaxhook.v2.ledger.mark");

    event CreditShortfall(PoolId indexed id, address quote, uint256 amount);
    event Rescued(PoolId indexed id, address indexed to, address quote, uint256 amount);

    error NotDisabled();

    constructor(address _hook) HookModuleBase(_hook) {}

    /// @notice Claimable balance (in `quote`) this module counts on holding in the hook: the sum of its pools'
    ///         shares. Always equal to `AvaxHookV2.claimable(module, quote)` after `reconcile`, unless someone
    ///         sent the module claims on their own.
    function accounted(address quote) public view returns (uint256) {
        uint256 a = _acc[quote];
        return a == 0 ? 0 : a - 1;
    }

    /// @notice Checks the last unverified credit against the hook's books (anyone; it only ever removes a
    ///         credit the hook didn't book).
    function reconcile() external {
        _reconcile();
    }

    /// @notice After the registry disabled this module (the hook no longer calls it), pays the share of the
    ///         pool of `token` to the pool's creator as a claim in the hook. Anyone.
    function rescue(address token) external virtual {
        AvaxHookV2 h = AvaxHookV2(payable(hook));
        if (!h.disabled(address(this))) revert NotDisabled();
        _reconcile();
        PoolId id = h.poolOfToken(token);
        (address quote, uint256 amount) = _takeShare(id);
        if (amount == 0) return;
        address creator = h.poolInfo(id).creator;
        _payClaim(quote, creator, amount);
        emit Rescued(id, creator, quote, amount);
    }

    /// @dev Zeroes pool `id`'s share and returns it (rescue).
    function _takeShare(PoolId id) internal virtual returns (address quote, uint256 amount);

    /// @dev The pool's unverified credit (quote asset, amount).
    function _unverified(PoolId id) internal view virtual returns (address quote, uint256 amount);

    /// @dev Clears the pool's unverified credit and removes `shortfall` (<= it) from the pool's share.
    function _verified(PoolId id, uint256 shortfall) internal virtual;

    /// @dev Call from onRegister for the pool's quote.
    function _seed(address quote) internal {
        if (_acc[quote] == 0) _acc[quote] = 1;
    }

    /// @dev Call after adding `amount` to pool `id`'s share and unverified credit (`+=`, after `_reconcile`).
    function _expect(PoolId id, address quote, uint256 amount) internal {
        _acc[quote] += amount;
        _pendingPool = id;
        uint256 d = AvaxHookV2(payable(hook)).dispatchId();
        bytes32 s = _MARK;
        assembly ("memory-safe") {
            tstore(s, d)
        }
    }

    /// @dev This module's claim left it (transferClaim / moduleSwap).
    function _spent(address quote, uint256 amount) internal {
        _acc[quote] -= amount;
    }

    /// @dev Settles the last unverified credit. Call before using any pool share or adding a new one.
    /// @return fresh the pending pool's unverified amount when it was announced in the hook's still-running
    ///         callback (not booked yet, so not checked now): never pay it out before it is verified.
    function _reconcile() internal returns (uint256 fresh) {
        PoolId id = _pendingPool;
        (address quote, uint256 amount) = _unverified(id);
        if (amount == 0) return 0;
        uint256 mark;
        bytes32 s = _MARK;
        assembly ("memory-safe") {
            mark := tload(s)
        }
        if (mark & 1 == 1 && mark == AvaxHookV2(payable(hook)).dispatchId()) return amount;
        uint256 actual = AvaxHookV2(payable(hook)).claimable(address(this), Currency.wrap(quote));
        uint256 acc = _acc[quote] - 1;
        uint256 short;
        if (actual < acc) {
            short = acc - actual;
            if (short > amount) short = amount;
            _acc[quote] -= short;
            emit CreditShortfall(id, quote, short);
        }
        _verified(id, short);
    }

    /// @dev Pays `amount` of this module's claim to `to`.
    function _payClaim(address quote, address to, uint256 amount) internal {
        _spent(quote, amount);
        AvaxHookV2(payable(hook)).transferClaim(Currency.wrap(quote), to, amount);
    }

    /// @dev True if `who` is one of pool `id`'s modules (other than this one) and not disabled.
    function _isPoolModule(PoolId id, address who) internal view returns (bool) {
        AvaxHookV2 h = AvaxHookV2(payable(hook));
        if (who == address(this) || h.disabled(who)) return false;
        address[] memory mods = h.poolInfo(id).modules;
        for (uint256 i; i < mods.length; ++i) {
            if (mods[i] == who) return true;
        }
        return false;
    }
}
