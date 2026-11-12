// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHookModule, ModuleCaps} from "./interfaces/IHookModule.sol";

interface IModuleKill {
    function disableModule(address module) external;
}

/// @title HookModuleRegistry
/// @notice The modules a v2 launch may pick, approved by the owner (the Safe). Each approval gets a
///         numeric id; the module's capabilities and conflict groups are read from it once, here, and
///         frozen into every pool that picks it at launch.
///
///   Status:
///     Active      new launches may use it.
///     Deprecated  new launches can't; pools that already use it keep running it unchanged. Reversible.
///     Disabled    emergency kill, irreversible: AvaxHookV2 stops calling the module for EVERY pool. It can
///                 only take a rule (and its cuts) away, never add one; meant for a module bug that bricks
///                 trades. This is the only power the owner has over live pools.
///
///   Trust (I-3): pools call a module's code at its address forever, so the owner must only approve immutable,
///   source-verified modules: no proxies, no upgradeable or self-destructible code. Each entry records the
///   module's `codehash` at approval so anyone can check it never changed (`codehashChanged`).
contract HookModuleRegistry is Ownable2Step {
    enum Status {
        None,
        Active,
        Deprecated,
        Disabled
    }

    struct Module {
        address impl;
        uint16 caps;
        uint32 groups;
        Status status;
        uint64 addedAt;
        bytes32 codehash; // extcodehash at approval (I-3: approve only immutable, verified modules, no proxies)
        string metadata; // JSON (name, category, description, params) or a URI to it — for the UI
    }

    address public hook;
    Module[] internal _modules; // id = index; 0 is a placeholder
    mapping(address => uint32) public idOf;

    event HookBound(address hook);
    event ModuleAdded(uint32 indexed id, address indexed impl, uint16 caps, uint32 groups, string metadata);
    event ModuleStatus(uint32 indexed id, Status status);
    event ModuleMetadata(uint32 indexed id, string metadata);

    error BadArgs();
    error UnknownModule();
    error NotActive();
    error AlreadyBound();

    constructor(address _owner) Ownable(_owner) {
        _modules.push();
    }

    /// @notice One-time binding to the v2 hook (deploy order: registry, hook, bind).
    function bindHook(address _hook) external onlyOwner {
        if (hook != address(0) || _hook == address(0)) revert AlreadyBound();
        hook = _hook;
        emit HookBound(_hook);
    }

    function addModule(address impl, string calldata metadata) external onlyOwner returns (uint32 id) {
        if (hook == address(0) || impl.code.length == 0 || idOf[impl] != 0) revert BadArgs();
        if (IHookModule(impl).hook() != hook) revert BadArgs();
        uint16 caps = IHookModule(impl).capabilities();
        if (caps == 0 || caps & ~ModuleCaps.ALL != 0) revert BadArgs();
        uint32 groups = IHookModule(impl).conflictGroups();
        id = uint32(_modules.length);
        _modules.push(Module(impl, caps, groups, Status.Active, uint64(block.timestamp), impl.codehash, metadata));
        idOf[impl] = id;
        emit ModuleAdded(id, impl, caps, groups, metadata);
    }

    function setMetadata(uint32 id, string calldata metadata) external onlyOwner {
        _module(id).metadata = metadata;
        emit ModuleMetadata(id, metadata);
    }

    /// @notice Stop (or, with `deprecated = false`, resume) offering a module to new launches.
    function setDeprecated(uint32 id, bool deprecated) external onlyOwner {
        Module storage m = _module(id);
        if (m.status == Status.Disabled) revert NotActive();
        m.status = deprecated ? Status.Deprecated : Status.Active;
        emit ModuleStatus(id, m.status);
    }

    /// @notice Emergency kill (irreversible): the hook skips this module in every pool from now on.
    function disable(uint32 id) external onlyOwner {
        Module storage m = _module(id);
        if (m.status == Status.Disabled) revert NotActive();
        m.status = Status.Disabled;
        IModuleKill(hook).disableModule(m.impl);
        emit ModuleStatus(id, Status.Disabled);
    }

    // ---------------------------------------------------------------- views

    /// @notice What the hook needs at launch; reverts unless the module is active.
    function forLaunch(uint32 id) external view returns (address impl, uint16 caps, uint32 groups) {
        if (id == 0 || id >= _modules.length) revert UnknownModule();
        Module storage m = _modules[id];
        if (m.status != Status.Active) revert NotActive();
        return (m.impl, m.caps, m.groups);
    }

    function getModule(uint32 id) external view returns (Module memory) {
        if (id == 0 || id >= _modules.length) revert UnknownModule();
        return _modules[id];
    }

    /// @notice True if module `id`'s code differs from what was approved.
    function codehashChanged(uint32 id) external view returns (bool) {
        Module storage m = _module(id);
        return m.impl.codehash != m.codehash;
    }

    function moduleCount() external view returns (uint256) {
        return _modules.length - 1;
    }

    /// @notice Every module with its id (1-based), for the UI's picker.
    function allModules() external view returns (uint32[] memory ids, Module[] memory list) {
        uint256 n = _modules.length - 1;
        ids = new uint32[](n);
        list = new Module[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint32(i + 1);
            list[i] = _modules[i + 1];
        }
    }

    function _module(uint32 id) internal view returns (Module storage) {
        if (id == 0 || id >= _modules.length) revert UnknownModule();
        return _modules[id];
    }
}
