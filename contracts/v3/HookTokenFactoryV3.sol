// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTokenV3} from "./HookTokenV3.sol";

/// @notice Deploys HookTokenV3s for the v3 launchpad (split out to keep the launchpad under 24KB).
///         Same ABI as HookTokenFactoryV2 — `create` has the identical selector — so the v3 stack runs
///         the deployed HookLaunchpadV2 code unchanged, with this factory in place of the v2 one.
contract HookTokenFactoryV3 {
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

    function create(
        string calldata name,
        string calldata symbol,
        HookTokenV3.Metadata calldata meta,
        address creator,
        uint256 supply
    ) external returns (address) {
        if (msg.sender != launchpad) revert NotAllowed();
        return address(new HookTokenV3(name, symbol, meta, creator, launchpad, hook, supply));
    }
}
