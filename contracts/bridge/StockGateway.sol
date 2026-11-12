// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BridgeAttestor} from "./BridgeAttestor.sol";
import {BridgedStock} from "./BridgedStock.sol";

/// @title StockGateway
/// @notice Avalanche side of the AvaxHook stock bridge. Mints the bridged stock tokens (mNVDA,
///         mTSLA, …) for locks the validators attest to on Robinhood Chain, and burns them to send
///         the real tokens back out of StockEscrow. Amounts here are bridged shares: 1 mNVDA is one
///         share of the escrow, worth `StockEscrow.originPerShare(NVDA)` NVDA (1 until a split), so a
///         stock split never touches this side.
contract StockGateway is BridgeAttestor {
    /// @notice Robinhood stock token => its bridged token here.
    mapping(address => BridgedStock) public bridged;
    address[] public originTokens;

    event StockCreated(address indexed originToken, address indexed bridgedToken, string name, string symbol);
    event Minted(uint64 indexed srcNonce, address indexed originToken, address indexed recipient, uint256 shares);
    event BurnedForRelease(
        uint64 indexed nonce, address indexed originToken, address indexed from, address recipient, uint256 shares, uint256 dstChainId
    );

    error UnknownStock();
    error AlreadyCreated();

    /// @param _robinhoodChainId 4663 on mainnet.
    constructor(address _owner, uint256 _robinhoodChainId) BridgeAttestor("AvaxHook StockGateway", _owner, _robinhoodChainId) {}

    /// @notice Deploys the bridged token for a Robinhood stock token, e.g. ("NVIDIA (bridged)", "mNVDA").
    function createStock(address originToken, string calldata name, string calldata symbol)
        external
        onlyOwner
        returns (BridgedStock token)
    {
        if (address(bridged[originToken]) != address(0)) revert AlreadyCreated();
        token = new BridgedStock(name, symbol, originToken);
        bridged[originToken] = token;
        originTokens.push(originToken);
        emit StockCreated(originToken, address(token), name, symbol);
    }

    /// @notice Mint bridged tokens for a lock the validators saw on Robinhood Chain. Anyone can submit.
    function mint(Transfer calldata t, bytes[] calldata signatures) external nonReentrant whenNotPaused {
        BridgedStock token = bridged[t.originToken];
        if (address(token) == address(0)) revert UnknownStock();
        _accept(t, signatures);
        token.mint(t.recipient, t.shares);
        emit Minted(t.nonce, t.originToken, t.recipient, t.shares);
    }

    /// @notice Burn `shares` bridged tokens to receive their stock on Robinhood Chain (at the escrow's
    ///         rate when released).
    function burn(address originToken, uint256 shares, address recipient) external nonReentrant whenNotPaused returns (uint64 nonce) {
        BridgedStock token = bridged[originToken];
        if (address(token) == address(0)) revert UnknownStock();
        _checkOutgoing(originToken, shares, recipient);
        token.burnFrom(msg.sender, shares);
        nonce = _nextNonce();
        emit BurnedForRelease(nonce, originToken, msg.sender, recipient, shares, remoteChainId);
    }

    function stockCount() external view returns (uint256) {
        return originTokens.length;
    }
}
