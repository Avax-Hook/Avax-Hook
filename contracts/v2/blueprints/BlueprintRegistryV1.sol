// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BlueprintRegistryV1
/// @notice The hook marketplace's on-chain catalog. A blueprint is a published rule set (module ids, their
///         configs and the core fees) that anyone can launch with or remix. Its author may ask for a royalty
///         (at most 0.5% of every trade's quote amount) paid by RoyaltyModule in every token or pool launched
///         from it; that module checks the author and the share here, so a launch can't credit a blueprint
///         it doesn't pay, and counts the use here.
///
///   - Permissionless publishing; the author, the share and the spec are fixed forever.
///   - `profile` says which module registry the ids belong to (0 = token launches, 1 = pools for existing
///     tokens); ids are not portable between profiles.
///   - The Safe (owner) can hide spam or impersonation from the marketplace and approves the royalty
///     modules allowed to record uses. A hidden blueprint can't be launched with any more (RoyaltyModule
///     refuses it); launches that already use it keep paying.
///   - Launching the same modules without RoyaltyModule is always possible: the royalty is an honour
///     system enforced by the app, not by the hook.
contract BlueprintRegistryV1 is Ownable2Step {
    struct Blueprint {
        address author;
        uint16 royaltyBps;
        uint8 profile;
        bool hidden;
        uint48 createdAt;
        uint32 remixOf; // parent blueprint id, 0 = original
        uint32 uses; // launches recorded by an approved RoyaltyModule
        bytes32 specHash; // keccak256(spec)
        string name;
        string uri; // off-chain description (JSON / ipfs / https)
    }

    uint16 public constant MAX_ROYALTY_BPS = 50; // 0.5%
    uint256 public constant MAX_MODULES = 8;
    uint256 public constant MAX_NAME = 64;
    uint256 public constant MAX_URI = 512;
    uint256 public constant MAX_SPEC = 8_192;

    Blueprint[] internal _blueprints; // id = index, 0 unused
    mapping(uint32 => bytes) internal _specs;
    mapping(address => uint32[]) internal _byAuthor;
    mapping(address => bool) public recorder;

    event Published(uint32 indexed id, address indexed author, uint8 profile, uint16 royaltyBps, uint32 remixOf, string name);
    event Hidden(uint32 indexed id, bool hidden);
    event Used(uint32 indexed id, address indexed module, bytes32 indexed poolId, address token);
    event RecorderSet(address indexed module, bool allowed);

    error BadArgs();
    error NotAuthor();
    error NotRecorder();
    error UnknownBlueprint();

    constructor(address _owner) Ownable(_owner) {
        _blueprints.push();
    }

    /// @param spec abi.encode(uint32[] moduleIds, bytes[] moduleConfigs, uint16 creatorFeeBps, uint24 baseFeePips)
    function publish(string calldata name, string calldata uri, uint8 profile, bytes calldata spec, uint16 royaltyBps, uint32 remixOf)
        external
        returns (uint32 id)
    {
        if (bytes(name).length == 0 || bytes(name).length > MAX_NAME || bytes(uri).length > MAX_URI) revert BadArgs();
        if (profile > 1 || royaltyBps > MAX_ROYALTY_BPS || spec.length > MAX_SPEC) revert BadArgs();
        if (remixOf != 0 && remixOf >= _blueprints.length) revert UnknownBlueprint();
        (uint32[] memory ids, bytes[] memory cfgs,,) = abi.decode(spec, (uint32[], bytes[], uint16, uint24));
        // RoyaltyModule takes one of the 8 module slots when the blueprint asks for a royalty.
        if (ids.length != cfgs.length || ids.length > (royaltyBps == 0 ? MAX_MODULES : MAX_MODULES - 1)) revert BadArgs();

        id = uint32(_blueprints.length);
        _blueprints.push(
            Blueprint({
                author: msg.sender,
                royaltyBps: royaltyBps,
                profile: profile,
                hidden: false,
                createdAt: uint48(block.timestamp),
                remixOf: remixOf,
                uses: 0,
                specHash: keccak256(spec),
                name: name,
                uri: uri
            })
        );
        _specs[id] = spec;
        _byAuthor[msg.sender].push(id);
        emit Published(id, msg.sender, profile, royaltyBps, remixOf, name);
    }

    /// @notice The author hides their own blueprint, or the owner hides spam. Owner only to unhide.
    function setHidden(uint32 id, bool hidden) external {
        Blueprint storage b = _get(id);
        if (msg.sender != owner() && (msg.sender != b.author || !hidden)) revert NotAuthor();
        b.hidden = hidden;
        emit Hidden(id, hidden);
    }

    function setRecorder(address module, bool allowed) external onlyOwner {
        recorder[module] = allowed;
        emit RecorderSet(module, allowed);
    }

    /// @notice Called by an approved RoyaltyModule when a launch registers with this blueprint.
    function recordUse(uint32 id, bytes32 poolId, address token) external {
        if (!recorder[msg.sender]) revert NotRecorder();
        Blueprint storage b = _get(id);
        unchecked {
            b.uses += 1;
        }
        emit Used(id, msg.sender, poolId, token);
    }

    // ---------------------------------------------------------------- views

    /// @notice What RoyaltyModule checks: author, share and profile of a launchable (published, not hidden)
    ///         blueprint.
    function royaltyOf(uint32 id) external view returns (address author, uint16 royaltyBps, uint8 profile, bool launchable) {
        if (id == 0 || id >= _blueprints.length) return (address(0), 0, 0, false);
        Blueprint storage b = _blueprints[id];
        return (b.author, b.royaltyBps, b.profile, !b.hidden);
    }

    function blueprint(uint32 id) external view returns (Blueprint memory) {
        return _get(id);
    }

    function specOf(uint32 id) external view returns (bytes memory) {
        _get(id);
        return _specs[id];
    }

    function byAuthor(address author) external view returns (uint32[] memory) {
        return _byAuthor[author];
    }

    function count() external view returns (uint256) {
        return _blueprints.length - 1;
    }

    /// @notice Newest-first page.
    function page(uint256 offset, uint256 limit) external view returns (uint32[] memory ids, Blueprint[] memory list) {
        uint256 n = _blueprints.length - 1;
        if (offset >= n) return (ids, list);
        uint256 c = n - offset < limit ? n - offset : limit;
        ids = new uint32[](c);
        list = new Blueprint[](c);
        for (uint256 i; i < c; ++i) {
            ids[i] = uint32(n - offset - i);
            list[i] = _blueprints[ids[i]];
        }
    }

    function _get(uint32 id) internal view returns (Blueprint storage) {
        if (id == 0 || id >= _blueprints.length) revert UnknownBlueprint();
        return _blueprints[id];
    }
}
