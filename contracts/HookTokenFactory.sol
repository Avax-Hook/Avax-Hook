// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookToken} from "./HookToken.sol";

/// @notice Deploys HookTokens for the launchpad. Split out so the launchpad stays under
///         the 24KB contract size limit. The launchpad is the token's mint recipient and
///         curve controller, so tokens are minted to it, not to this factory.
contract HookTokenFactory {
    address public immutable deployer;
    address public launchpad;

    error NotAllowed();

    constructor() {
        deployer = msg.sender;
    }

    function bindLaunchpad(address _launchpad) external {
        if (msg.sender != deployer || launchpad != address(0) || _launchpad == address(0)) revert NotAllowed();
        launchpad = _launchpad;
    }

    function create(string calldata name, string calldata symbol, HookToken.Metadata calldata meta, address creator, uint256 supply)
        external
        returns (address)
    {
        if (msg.sender != launchpad) revert NotAllowed();
        return address(new HookToken(name, symbol, meta, creator, launchpad, supply));
    }
}
