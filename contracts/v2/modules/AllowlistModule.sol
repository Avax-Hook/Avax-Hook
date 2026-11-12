// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {ReceiverRuleBase} from "./ReceiverRuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";

/// @title AllowlistModule
/// @notice Transfer rule: only allowed accounts can RECEIVE this token (curve buys, pool buys, wallet-to-wallet
///         transfers), from launch until `duration` seconds after the pool
///         opens (0 = forever; at most 365 days otherwise). Selling and sending are never limited.
///   Who is allowed (either source, or both):
///   - `list`: up to 200 addresses written at launch.
///   - `root`: a Merkle root for bigger lists. A proof can't travel through a token transfer, so an account is
///     marked allowed first, by anyone, with `prove(token, account, proof)`, or in the same trade: a curve
///     buy through `buyWithData` or a pool buy through the AvaxHook router with `extra = abi.encode(bytes32[]
///     proof)` marks the trader. Once marked, always marked (for this token).
///   Leaf format (OpenZeppelin double-hash, as `StandardMerkleTree.of(values, ["address"])` builds it):
///     leaf = keccak256(bytes.concat(keccak256(abi.encode(account))))
///   (`abi.encode` of a single address equals the 32-byte left-padded word; pairs are hashed sorted, as
///   MerkleProof.verify expects.)
///   - Always exempt receivers: the PoolManager, the launchpad, the hook, 0x…dEaD, this module, other modules
///     of the same pool, the creator.
///   - Every token outflow of the PoolManager is a buy and checked (this pool, hookless or other pools of the
///     token, output taken before or after the swap), except this pool's LP withdrawals and fee collection,
///     covered by a per-transaction allowance (see ReceiverRuleBase). Token claims from the hook and
///     withdrawals from other pools must go to a qualifying address.
///     Liquidity added in one transaction and removed in a later one pays out to anyone (accepted).
///   - Contracts that hold tokens mid-route (aggregators) must be allowed too, so aggregator buys mostly fail
///     while the list runs; the router and the curve pay the buyer directly.
///   - Bypass: an allowed wallet can buy and pass tokens on to other allowed wallets only; it can't hand them
///     to outsiders while the list runs. Sharing a private key gets around everything.
///   - Claims bypass guard (2026-11-12): While the list applies (`duration` after the pool opens, or forever), pool buys that don't come through the
///     AvaxHook router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly():
///     such a swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the
///     ERC-20, so this rule would never see them. Trade through the AvaxHook router (site, Zap, limit orders)
///     or the curve.
contract AllowlistModule is ReceiverRuleBase {
    struct Config {
        address[] list; // up to 200 addresses allowed at launch
        bytes32 root; // Merkle root of more allowed accounts, 0 = none
        uint32 duration; // seconds after the pool opens, 0 = forever (max 365 days)
    }

    struct Rule {
        bytes32 root;
        uint32 duration;
        address creator;
        bool registered;
    }

    uint256 public constant MAX_LIST = 200;
    uint32 public constant MAX_DURATION = 365 days;

    mapping(PoolId => Rule) internal _rules;
    mapping(PoolId => mapping(address => bool)) internal _allowed;
    mapping(address => PoolId) public poolOf;

    event Allowed(address indexed token, address indexed account, bool byProof);

    error NotAllowed(address receiver);
    error BadProof();
    error UnknownToken();

    constructor(address _hook) ReceiverRuleBase(_hook) {}

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY;
    }

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_RECEIVER_LIST;
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        uint256 n = c.list.length;
        if (n > MAX_LIST || (n == 0 && c.root == bytes32(0)) || c.duration > MAX_DURATION) revert BadConfig();
        for (uint256 i; i < n; ++i) {
            if (c.list[i] == address(0)) revert BadConfig();
        }
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Rule storage r = _rules[id];
        if (r.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        mapping(address => bool) storage a = _allowed[id];
        for (uint256 i; i < c.list.length; ++i) {
            if (a[c.list[i]]) continue;
            a[c.list[i]] = true;
            emit Allowed(token, c.list[i], false);
        }
        (r.root, r.duration, r.creator, r.registered) = (c.root, c.duration, creator, true);
        poolOf[token] = id;
        _registerPool(id, token, quote);
    }

    /// @dev Router / curve buys with `extra = abi.encode(bytes32[] proof)` mark the trader allowed. A missing,
    ///      malformed or wrong proof is ignored here; the token transfer then decides.
    ///      Claims bypass guard: while the list applies, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external override onlyHook returns (uint24, Credit[] memory) {
        address trader = ctx.trader;
        if (ctx.isBuy && _active(ctx.poolId, _rules[ctx.poolId])) RouterOnlyGuard.check(ctx);
        if (ctx.isBuy && trader != address(0) && ctx.extra.length != 0) {
            Rule storage r = _rules[ctx.poolId];
            if (r.root != bytes32(0) && !_allowed[ctx.poolId][trader]) {
                try this.decodeProof(ctx.extra) returns (bytes32[] memory proof) {
                    if (MerkleProof.verify(proof, r.root, leaf(trader))) {
                        _allowed[ctx.poolId][trader] = true;
                        emit Allowed(ctx.token, trader, true);
                    }
                } catch {}
            }
        }
        return (0, new Credit[](0));
    }

    function onTransfer(PoolId id, address, address, address from, address to, uint256 amount) external override onlyHook {
        Rule storage r = _rules[id];
        if (_allowed[id][to] || to == r.creator || _plumbing(to) || !_active(id, r)) return;
        if (!_excused(id, from, to, amount)) revert NotAllowed(to);
    }

    /// @notice Marks `account` allowed for `token` with a Merkle proof. Permissionless (anyone may pay the gas).
    function prove(address token, address account, bytes32[] calldata proof) external {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        if (!r.registered) revert UnknownToken();
        if (_allowed[id][account]) return;
        if (r.root == bytes32(0) || !MerkleProof.verifyCalldata(proof, r.root, leaf(account))) revert BadProof();
        _allowed[id][account] = true;
        emit Allowed(token, account, true);
    }

    // ---------------------------------------------------------------- views

    /// @notice The Merkle leaf of `account`: keccak256(bytes.concat(keccak256(abi.encode(account)))).
    function leaf(address account) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    /// @dev Helper for try/catch decoding of a router/curve `extra`.
    function decodeProof(bytes calldata extra) external pure returns (bytes32[] memory) {
        return abi.decode(extra, (bytes32[]));
    }

    function isAllowed(address token, address account) external view returns (bool) {
        return _allowed[poolOf[token]][account];
    }

    /// @notice Whether `account` may receive `token` right now.
    function canReceive(address token, address account) external view returns (bool) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        return !r.registered || _allowed[id][account] || account == r.creator || _plumbing(account) || _isPoolModule(id, account)
            || !_active(id, r);
    }

    /// @return root  the Merkle root (0 = list only)
    /// @return until when the list lifts (type(uint256).max = never; 0 = pool not open yet)
    function allowlist(address token) external view returns (bytes32 root, uint256 until) {
        PoolId id = poolOf[token];
        Rule storage r = _rules[id];
        uint256 opened = _openedAt(id);
        until = r.duration == 0 ? type(uint256).max : opened == 0 ? 0 : opened + r.duration;
        return (r.root, until);
    }

    // ---------------------------------------------------------------- internals

    function _active(PoolId id, Rule storage r) internal view returns (bool) {
        if (r.duration == 0) return true;
        uint256 opened = _openedAt(id);
        return opened == 0 || block.timestamp < opened + r.duration;
    }
}
