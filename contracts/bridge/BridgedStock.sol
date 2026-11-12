// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title BridgedStock
/// @notice A Robinhood stock token on Avalanche (e.g. mNVDA): one share of the real token held in
///         StockEscrow on Robinhood Chain, redeemable for `StockEscrow.originPerShare` of it (1:1 until
///         a balance-changing split, after which the escrow's rate, not this token, absorbs the ratio). Only the StockGateway can mint (after an attested lock)
///         or burn (to send it back). A plain ERC-20 otherwise: no fees, no rebasing, no blacklist,
///         so it works as a Uniswap v4 quote asset.
contract BridgedStock is ERC20, ERC20Permit {
    address public immutable gateway;
    /// @notice The stock token on Robinhood Chain this represents.
    address public immutable originToken;

    error OnlyGateway();

    constructor(string memory name_, string memory symbol_, address originToken_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        gateway = msg.sender;
        originToken = originToken_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != gateway) revert OnlyGateway();
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != gateway) revert OnlyGateway();
        _burn(from, amount);
    }
}
