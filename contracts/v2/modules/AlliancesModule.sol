// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModuleCaps} from "../interfaces/IHookModule.sol";
import {ReceiverRuleBase} from "./ReceiverRuleBase.sol";
import {RouterOnlyGuard} from "./lib/RouterOnlyGuard.sol";
import {BalanceRead} from "./lib/BalanceRead.sol";

/// @title AlliancesModule
/// @notice Token diplomacy. A token names up to 4 allies and up to 4 rivals (other tokens):
///   - Rival: a wallet holding at least the rival threshold of any rival token can't RECEIVE this token
///     (curve buys, pool buys and wallet transfers are refused). Each rival's threshold is the larger of
///     `rivalMin` and 0.1% of that rival's total supply (`MIN_RIVAL_BPS`), fixed when the rival is added
///     (`rivalMinOf`), so a rival with other decimals or supply still gets a meaningful bar.
///   - Ally (visa): a wallet holding at least `allyMin` of any ally token skips this token's own holding cap
///     (`capBps` of the supply per wallet, 0 = no cap). The cap is a holding cap (GROUP_HOLDING_CAP), so this
///     module can't be combined with Max per wallet and the like.
///   Treaty tokens (at launch and after) must be AvaxHook v2 tokens or quote assets the live QuoteRegistry
///   allows, so nobody can point the rule at a token whose `balanceOf` it controls.
///   Treaties:
///   - At launch: one-way, from the config.
///   - After launch, by the token's creator (as recorded in the hook): `proposeTreaty(token, other, kind)`.
///     A rivalry (v2 token or allowed quote) takes effect at once (one-way). An alliance (v2 tokens only)
///     waits until the other token's creator calls `acceptAlliance(other, token)`; then `other` becomes an
///     ally of `token` and, if `other` also runs this module, `token` becomes an ally of `other` (mutual
///     visas). Entries an acceptance added are marked (`viaAlliance`).
///   - `dropTreaty(token, other)` by the token's creator removes `token`'s own entry for `other` (any origin;
///     a rivalry is lifted, a pending proposal withdrawn) and, on the other side, only the entry the accepted
///     alliance added. An ally the other token named in its own launch config stays.
///   Limits and honesty:
///   - Griefing: the rival check reads a balance anyone can push to. Anyone can bar a wallet from receiving
///     this token by SENDING it a rival's threshold. The threshold floor (0.1% of the rival's supply, at
///     least `rivalMin`) makes that cost real (the attacker gives the victim the tokens), but it stays
///     possible; the victim can lift it by moving the rival tokens out.
///   - Balances of treaty tokens are read with a 20k gas budget each (at most 8 reads, under the 200k module
///     budget); a failing read counts as 0 (no visa; not a rival holder).
///   - Selling and sending are never limited. Exempt receivers: the PoolManager, the launchpad, the hook,
///     0x…dEaD, this module, other modules of the same pool, the creator.
///   - Every token outflow of the PoolManager is a buy and checked (this pool, hookless or other pools of the
///     token, output taken before or after the swap), except this pool's LP withdrawals and fee collection,
///     covered by a per-transaction allowance (see ReceiverRuleBase). Token claims from the hook and
///     withdrawals from other pools must go to a qualifying address.
///   - Bypass: balances are checked at receive time only. A rival holder can move the rival tokens to another
///     wallet first, or receive here into a fresh wallet; a visa can be borrowed for the moment of the buy;
///     liquidity added in one transaction and removed in a later one pays out to anyone.
///     Aggregator contracts holding tokens mid-route are receivers too (they rarely hold rival tokens, but
///     they are held to the cap).
///   - The creator CAN declare a widely held v2 token or quote asset a rival after launch, which shuts its
///     holders out of buying. Buyers should read this card as "the creator can add rivals later".
///   - Claims bypass guard (2026-11-12): While the pact has a rival or a holding cap, pool swaps that don't come through the AvaxHook
///     router (aggregators and bots calling the PoolManager directly) are refused with RouterOnly(): such a
///     swap can keep the tokens as PoolManager (ERC-6909) claims, which never move the ERC-20, so this rule
///     would never see them. Trade through the AvaxHook router (site, Zap, limit orders) or the curve.
contract AlliancesModule is ReceiverRuleBase {
    struct Config {
        uint16 capBps; // own per-wallet cap, of the 1B supply: 0 = none, else 0.1% .. 50%
        uint256 allyMin; // ally-token balance that grants a visa (ally token units), > 0
        uint256 rivalMin; // rival-token balance that bars a wallet (rival token units), > 0; raised per rival
        // to 0.1% of that rival's supply when lower
        address[] allies; // up to 4
        address[] rivals; // up to 4
    }

    struct Pact {
        address creator;
        uint16 capBps;
        uint8 nAllies;
        uint8 nRivals;
        bool registered;
        address token;
        uint256 allyMin;
        uint256 rivalMin;
        address[4] allies;
        address[4] rivals;
        uint256[4] rivalMins; // effective threshold per rival: max(rivalMin, MIN_RIVAL_BPS of its supply)
    }

    uint8 public constant ALLY = 1;
    uint8 public constant RIVAL = 2;
    uint256 public constant MAX_TREATIES = 4;
    uint16 public constant MIN_CAP_BPS = 10;
    uint16 public constant MAX_CAP_BPS = 5_000;
    /// @notice Floor of each rival's threshold, in bps of the rival token's total supply (0.1%).
    uint16 public constant MIN_RIVAL_BPS = 10;
    uint256 internal constant READ_GAS = 20_000;

    mapping(PoolId => Pact) internal _pacts;
    mapping(address => PoolId) public poolOf;
    /// @notice proposer token => other token => alliance proposal pending
    mapping(address => mapping(address => bool)) public proposed;
    /// @notice token => ally => the ally entry was added by an accepted alliance (not the launch config)
    mapping(address => mapping(address => bool)) public viaAlliance;

    event AllyAdded(address indexed token, address indexed ally, bool atLaunch);
    event RivalAdded(address indexed token, address indexed rival, bool atLaunch);
    event AllianceProposed(address indexed token, address indexed other);
    event AllianceFormed(address indexed token, address indexed other, bool mutual);
    event AllyRemoved(address indexed token, address indexed ally);
    event RivalRemoved(address indexed token, address indexed rival);
    event ProposalWithdrawn(address indexed token, address indexed other);

    error RivalHolder(address receiver, address rivalToken);
    error CapExceeded(address wallet, uint256 balance, uint256 cap);
    error NotCreator();
    error UnknownToken();
    error BadTreaty();
    error TooManyTreaties();
    error NoProposal();
    error NoTreaty();

    constructor(address _hook) ReceiverRuleBase(_hook) {}

    function conflictGroups() external pure override returns (uint32) {
        return ModuleCaps.GROUP_HOLDING_CAP;
    }

    function capabilities() external pure override returns (uint16) {
        return ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY;
    }

    /// @dev Claims bypass guard: while the pact has a rival or a cap, pool buys must come through the AvaxHook router.
    function onBeforeSwap(SwapContext calldata ctx) external view override onlyHook returns (uint24, Credit[] memory) {
        if (ctx.isBuy) {
            Pact storage p = _pacts[ctx.poolId];
            if (p.nRivals != 0 || p.capBps != 0) RouterOnlyGuard.check(ctx);
        }
        return (0, new Credit[](0));
    }

    function validateConfig(bytes calldata config) public pure override {
        Config memory c = abi.decode(config, (Config));
        if (c.capBps != 0 && (c.capBps < MIN_CAP_BPS || c.capBps > MAX_CAP_BPS)) revert BadConfig();
        if (c.allyMin == 0 || c.rivalMin == 0) revert BadConfig();
        if (c.allies.length > MAX_TREATIES || c.rivals.length > MAX_TREATIES) revert BadConfig();
        for (uint256 i; i < c.allies.length; ++i) {
            if (c.allies[i] == address(0)) revert BadConfig();
            for (uint256 j; j < i; ++j) {
                if (c.allies[j] == c.allies[i]) revert BadConfig();
            }
            for (uint256 j; j < c.rivals.length; ++j) {
                if (c.rivals[j] == c.allies[i]) revert BadConfig();
            }
        }
        for (uint256 i; i < c.rivals.length; ++i) {
            if (c.rivals[i] == address(0)) revert BadConfig();
            for (uint256 j; j < i; ++j) {
                if (c.rivals[j] == c.rivals[i]) revert BadConfig();
            }
        }
    }

    function onRegister(PoolId id, address token, address quote, address creator, bytes calldata config) external override onlyHook {
        validateConfig(config);
        Pact storage p = _pacts[id];
        if (p.registered) revert AlreadyRegistered();
        Config memory c = abi.decode(config, (Config));
        (p.creator, p.capBps, p.registered, p.token, p.allyMin, p.rivalMin) =
            (creator, c.capBps, true, token, c.allyMin, c.rivalMin);
        for (uint256 i; i < c.allies.length; ++i) {
            _checkToken(c.allies[i], token);
            p.allies[i] = c.allies[i];
            emit AllyAdded(token, c.allies[i], true);
        }
        for (uint256 i; i < c.rivals.length; ++i) {
            _checkToken(c.rivals[i], token);
            p.rivals[i] = c.rivals[i];
            p.rivalMins[i] = _rivalThreshold(c.rivals[i], c.rivalMin);
            emit RivalAdded(token, c.rivals[i], true);
        }
        p.nAllies = uint8(c.allies.length);
        p.nRivals = uint8(c.rivals.length);
        poolOf[token] = id;
        _registerPool(id, token, quote);
    }

    function onTransfer(PoolId id, address token, address, address from, address to, uint256 amount) external override onlyHook {
        Pact storage p = _pacts[id];
        if (to == p.creator || _plumbing(to)) return;
        uint256 n = p.nRivals;
        if (n != 0) {
            for (uint256 i; i < n; ++i) {
                address rv = p.rivals[i];
                if (BalanceRead.balanceOr0(rv, to, READ_GAS) >= p.rivalMins[i]) {
                    if (_excused(id, from, to, amount)) return;
                    revert RivalHolder(to, rv);
                }
            }
        }
        uint16 capBps = p.capBps;
        if (capBps == 0) return;
        uint256 cap = (TOTAL_SUPPLY * capBps) / BPS;
        uint256 bal = IERC20(token).balanceOf(to);
        if (bal <= cap || _hasVisa(p, to) || _excused(id, from, to, amount)) return;
        revert CapExceeded(to, bal, cap);
    }

    // ---------------------------------------------------------------- diplomacy

    /// @notice The creator of `token` proposes an alliance with, or declares a rivalry against, `other`
    ///         (an AvaxHook v2 token). Rivals apply at once; alliances wait for `acceptAlliance`.
    function proposeTreaty(address token, address other, uint8 kind) external {
        Pact storage p = _pactOf(token);
        if (msg.sender != p.creator) revert NotCreator();
        if (other == token || other.code.length == 0) revert BadTreaty();
        if (_indexOf(p.allies, p.nAllies, other) < MAX_TREATIES || _indexOf(p.rivals, p.nRivals, other) < MAX_TREATIES) {
            revert BadTreaty();
        }
        if (kind == RIVAL) {
            if (!_v2OrQuote(other)) revert BadTreaty();
            if (p.nRivals >= MAX_TREATIES) revert TooManyTreaties();
            p.rivalMins[p.nRivals] = _rivalThreshold(other, p.rivalMin);
            p.rivals[p.nRivals++] = other;
            delete proposed[token][other];
            emit RivalAdded(token, other, false);
        } else if (kind == ALLY) {
            if (_v2Creator(other) == address(0)) revert BadTreaty();
            if (p.nAllies >= MAX_TREATIES) revert TooManyTreaties();
            proposed[token][other] = true;
            emit AllianceProposed(token, other);
        } else {
            revert BadTreaty();
        }
    }

    /// @notice The creator of `token` accepts `proposer`'s alliance: `token` becomes an ally of `proposer`, and
    ///         if `token` runs this module too, `proposer` becomes an ally of `token`.
    function acceptAlliance(address token, address proposer) external {
        if (!proposed[proposer][token]) revert NoProposal();
        if (msg.sender != _v2Creator(token)) revert NotCreator();
        Pact storage pp = _pactOf(proposer);
        delete proposed[proposer][token];
        if (_indexOf(pp.rivals, pp.nRivals, token) < MAX_TREATIES) revert BadTreaty();
        if (_indexOf(pp.allies, pp.nAllies, token) == MAX_TREATIES) {
            if (pp.nAllies >= MAX_TREATIES) revert TooManyTreaties();
            pp.allies[pp.nAllies++] = token;
            viaAlliance[proposer][token] = true;
            emit AllyAdded(proposer, token, false);
        }
        Pact storage tp = _pacts[poolOf[token]];
        bool mutual = tp.registered && tp.token == token;
        if (mutual) {
            if (_indexOf(tp.rivals, tp.nRivals, proposer) < MAX_TREATIES) revert BadTreaty();
            if (_indexOf(tp.allies, tp.nAllies, proposer) == MAX_TREATIES) {
                if (tp.nAllies >= MAX_TREATIES) revert TooManyTreaties();
                tp.allies[tp.nAllies++] = proposer;
                viaAlliance[token][proposer] = true;
                emit AllyAdded(token, proposer, false);
            }
        }
        emit AllianceFormed(proposer, token, mutual);
    }

    /// @notice The creator of `token` ends its treaty with `other`: an alliance is broken both ways, a rivalry
    ///         is lifted, a pending alliance proposal is withdrawn.
    function dropTreaty(address token, address other) external {
        Pact storage p = _pactOf(token);
        if (msg.sender != p.creator) revert NotCreator();
        bool done;
        if (_removeAlly(p, other)) {
            done = true;
            delete viaAlliance[token][other];
            // the other side loses only the entry the accepted alliance added, never its own launch ally
            if (viaAlliance[other][token]) {
                delete viaAlliance[other][token];
                Pact storage op = _pacts[poolOf[other]];
                if (op.registered && op.token == other) _removeAlly(op, token);
            }
        }
        uint256 r = _indexOf(p.rivals, p.nRivals, other);
        if (r < MAX_TREATIES) {
            uint8 last = --p.nRivals;
            p.rivals[r] = p.rivals[last];
            p.rivalMins[r] = p.rivalMins[last];
            delete p.rivals[last];
            delete p.rivalMins[last];
            emit RivalRemoved(token, other);
            done = true;
        }
        if (proposed[token][other]) {
            delete proposed[token][other];
            emit ProposalWithdrawn(token, other);
            done = true;
        }
        if (!done) revert NoTreaty();
    }

    // ---------------------------------------------------------------- views

    function treaties(address token)
        external
        view
        returns (address[] memory allies, address[] memory rivals, uint16 capBps, uint256 allyMin, uint256 rivalMin)
    {
        Pact storage p = _pacts[poolOf[token]];
        allies = new address[](p.nAllies);
        rivals = new address[](p.nRivals);
        for (uint256 i; i < allies.length; ++i) allies[i] = p.allies[i];
        for (uint256 i; i < rivals.length; ++i) rivals[i] = p.rivals[i];
        return (allies, rivals, p.capBps, p.allyMin, p.rivalMin);
    }

    /// @return barredBy the first rival token `wallet` holds enough of (address(0) = none)
    /// @return visa     whether `wallet` holds enough of an ally token to skip the cap
    function standing(address token, address wallet) external view returns (address barredBy, bool visa) {
        Pact storage p = _pacts[poolOf[token]];
        for (uint256 i; i < p.nRivals; ++i) {
            if (BalanceRead.balanceOr0(p.rivals[i], wallet, READ_GAS) >= p.rivalMins[i]) {
                barredBy = p.rivals[i];
                break;
            }
        }
        visa = _hasVisa(p, wallet);
    }

    /// @notice The balance of `rival` that bars a wallet from receiving `token` (0 = not a rival of it).
    function rivalMinOf(address token, address rival) external view returns (uint256) {
        Pact storage p = _pacts[poolOf[token]];
        uint256 i = _indexOf(p.rivals, p.nRivals, rival);
        return i < MAX_TREATIES ? p.rivalMins[i] : 0;
    }

    // ---------------------------------------------------------------- internals

    /// @dev max(rivalMin, MIN_RIVAL_BPS of the rival's total supply). A rival whose supply can't be read is
    ///      refused: without it the floor can't be set.
    function _rivalThreshold(address rival, uint256 rivalMin) internal view returns (uint256) {
        (bool ok, bytes memory ret) = rival.staticcall{gas: READ_GAS}(abi.encodeCall(IERC20.totalSupply, ()));
        if (!ok || ret.length < 32) revert BadTreaty();
        uint256 floor = (abi.decode(ret, (uint256)) * MIN_RIVAL_BPS) / BPS;
        if (floor == 0) floor = 1;
        return rivalMin > floor ? rivalMin : floor;
    }

    function _hasVisa(Pact storage p, address who) internal view returns (bool) {
        uint256 n = p.nAllies;
        uint256 min = p.allyMin;
        for (uint256 i; i < n; ++i) {
            if (BalanceRead.balanceOr0(p.allies[i], who, READ_GAS) >= min) return true;
        }
        return false;
    }

    function _removeAlly(Pact storage p, address other) internal returns (bool) {
        uint256 a = _indexOf(p.allies, p.nAllies, other);
        if (a == MAX_TREATIES) return false;
        uint8 last = --p.nAllies;
        p.allies[a] = p.allies[last];
        delete p.allies[last];
        emit AllyRemoved(p.token, other);
        return true;
    }

    function _indexOf(address[4] storage list, uint256 n, address a) internal view returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (list[i] == a) return i;
        }
        return MAX_TREATIES;
    }

    function _pactOf(address token) internal view returns (Pact storage p) {
        p = _pacts[poolOf[token]];
        if (!p.registered || p.token != token) revert UnknownToken();
    }

    function _checkToken(address t, address self) internal view {
        _checkForeignToken(t, self);
        (bool ok,) = BalanceRead.balanceOf(t, address(this), READ_GAS);
        if (!ok) revert BadTreaty();
    }
}
