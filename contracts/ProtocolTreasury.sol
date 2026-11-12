// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title AvaxHook Protocol Treasury
contract ProtocolTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount, string memo);
    event NativeWithdrawn(address indexed to, uint256 amount, string memo);
    event NativeReceived(address indexed from, uint256 amount);

    error ZeroAddress();
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    function withdrawToken(IERC20 token, address to, uint256 amount, string calldata memo) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit TokenWithdrawn(address(token), to, amount, memo);
        token.safeTransfer(to, amount);
    }

    function withdrawNative(address payable to, uint256 amount, string calldata memo) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit NativeWithdrawn(to, amount, memo);
        Address.sendValue(to, amount);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
