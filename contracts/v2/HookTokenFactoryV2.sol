// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV2} from "./HookTokenV2.sol";

/// @notice Deploys HookTokenV2s for the v2 launchpad (split out to keep the launchpad under 24KB).
contract HookTokenFactoryV2 {
    address public immutable deployer;
    address public immutable hook;
    address public launchpad;

    error NotAllowed();

    constructor(address _hook) {
        deployer = msg.sender;
        hook = _hook;
    }

    function bindLaunchpad(address _launchpad) external {
        if (msg.sender != deployer || launchpad != address(0) || _launchpad == address(0)) revert NotAllowed();
        launchpad = _launchpad;
    }

    function create(string calldata name, string calldata symbol, HookTokenV2.Metadata calldata meta, address creator, uint256 supply)
        external
        returns (address)
    {
        if (msg.sender != launchpad) revert NotAllowed();
        return address(new HookTokenV2(name, symbol, meta, creator, launchpad, hook, supply));
    }
}
