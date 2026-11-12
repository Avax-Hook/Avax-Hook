// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookModuleRegistry} from "../contracts/v2/HookModuleRegistry.sol";
import {IHookModule} from "../contracts/v2/interfaces/IHookModule.sol";

interface IHookBindings {
    function launchpad() external view returns (address);
    function moduleRegistry() external view returns (address);
}

/// Deploys every module of the live v2 registry again against the v3 hook, and approves it in the v3
/// registry **in the same order**, so a module keeps its id: id 1 is Anti-snipe on both stacks, which is
/// what every published blueprint, the marketplace and the bundled config/hook-modules/*.json files
/// assume. A module's `hook` is immutable, which is why the code has to be deployed again at all.
///
/// The list comes from `script/v3-modules.json` — `node script/gen-v3-modules.mjs` reads it off the live
/// v2 registry, so this script never guesses what is registered or in which order. By default each entry
/// is stored with the short metadata (id, name, contract): the site merges on-chain metadata with the
/// bundled JSON of the same id, and storing all 55 full JSON documents again would cost ~120 KB of
/// calldata and storage for nothing. `V3_METADATA=full` stores exactly what v2 has instead.
///
///   node script/gen-v3-modules.mjs
///   HOOK_V3=0x… REGISTRY_V3=0x… forge script script/DeployV3Modules.s.sol --rpc-url avalanche --broadcast --slow
///
/// Env: ADMIN_PRIVATE_KEY (deployer, pays gas; must still be the v3 registry's owner — Ownable2Step keeps
///      it there until the Safe accepts), HOOK_V3, REGISTRY_V3 (default: the hook's own registry),
///      OWNER (the Safe — owns the modules that take an owner), ARCADE_SCORES (default: the live one,
///      shared with v2; the Safe then has to `setBinder(<v3 Arcade>, true)`), BLUEPRINTS (default: the
///      live BlueprintRegistryV1; the Safe then has to `setRecorder(<v3 Royalty>, true)`),
///      FROM_ID / TO_ID (default 1 .. count — to carry on after a failed run), V3_METADATA=min|full.
///
/// Prints `V3 MODULE <Name> <addr>` lines for the runbook, and `V3 NEUTRAL <addr>` for the modules the
/// live Zap treats as aggregator-neutral: that list goes into DeployV3Periphery's `NEUTRAL`.
contract DeployV3Modules is Script {
    address constant LIVE_ARCADE_SCORES = 0xF2FB487D5e638d6C04ba2B004C0E564Bcc7388Ab;
    address constant LIVE_BLUEPRINTS = 0x79114a00eA631b8F0fD83C2D6B060e883e7f8717;
    address constant SAFE = 0x88Da9BA0Ed5854651A688E9bCfb46Fe13DbC735B;
    // Polarity's price assets, as on v2: the QuoteRegistry quotes backed by Chainlink aggregators.
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    uint8 constant LAUNCH_PROFILE = 0; // RoyaltyModule: blueprints published for token launches

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address hook = vm.envAddress("HOOK_V3");
        require(hook.code.length > 0, "no code at HOOK_V3");
        require(IHookBindings(hook).launchpad() != address(0), "bind the v3 launchpad first: modules read hook.launchpad()");
        HookModuleRegistry registry =
            HookModuleRegistry(vm.envOr("REGISTRY_V3", IHookBindings(hook).moduleRegistry()));
        require(registry.hook() == hook, "REGISTRY_V3 is not bound to HOOK_V3");
        require(registry.owner() == vm.addr(pk), "the deployer must still own the v3 registry");
        address owner = vm.envOr("OWNER", SAFE);
        address scores = vm.envOr("ARCADE_SCORES", LIVE_ARCADE_SCORES);
        address blueprints = vm.envOr("BLUEPRINTS", LIVE_BLUEPRINTS);
        bool full = _eq(vm.envOr("V3_METADATA", string("min")), "full");

        string memory raw = vm.readFile("script/v3-modules.json");
        string[] memory names = vm.parseJsonStringArray(raw, ".contracts");
        string[] memory meta = vm.parseJsonStringArray(raw, full ? ".metadata" : ".metadataMin");
        bool[] memory neutral = vm.parseJsonBoolArray(raw, ".neutral");
        require(names.length == meta.length && names.length == neutral.length, "manifest arrays disagree");

        uint256 from = vm.envOr("FROM_ID", uint256(1));
        uint256 to = vm.envOr("TO_ID", names.length);
        require(from >= 1 && to <= names.length && from <= to, "FROM_ID / TO_ID out of range");
        require(registry.moduleCount() == from - 1, "the registry is not at FROM_ID - 1: ids would not line up");

        address[] memory impls = new address[](to + 1);
        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (address(0), USDC, USDT);

        vm.startBroadcast(pk);
        for (uint256 id = from; id <= to; ++id) {
            string memory name = names[id - 1];
            bytes memory args = abi.encode(hook);
            if (_eq(name, "ArcadeModule")) args = abi.encode(hook, scores);
            else if (_eq(name, "PartnerFeeModule") || _eq(name, "UnderwaterModule")) args = abi.encode(hook, owner);
            else if (_eq(name, "PolarityModule")) args = abi.encode(hook, assets);
            else if (_eq(name, "RoyaltyModule")) args = abi.encode(hook, blueprints, LAUNCH_PROFILE);
            address m = _deploy(name, args);
            require(IHookModule(m).hook() == hook, "module bound to another hook");
            uint32 got = registry.addModule(m, meta[id - 1]);
            require(got == id, "id mismatch: the v3 registry would hand out a different id than v2");
            impls[id] = m;
            console2.log("V3 MODULE", name, m);
        }
        vm.stopBroadcast();

        console2.log("--- aggregator-neutral modules (DeployV3Periphery NEUTRAL=) ---");
        for (uint256 id = from; id <= to; ++id) {
            if (neutral[id - 1]) console2.log("V3 NEUTRAL", impls[id]);
        }
        console2.log("registered", to - from + 1, "modules; registry count now", registry.moduleCount());
        console2.log("Safe, afterwards: ArcadeScores.setBinder(<v3 Arcade>, true), Blueprints.setRecorder(<v3 Royalty>, true)");
    }

    /// @dev `vm.getCode` + CREATE, so the script needs no import per module (55 of them) and the
    ///      manifest alone decides what is deployed.
    function _deploy(string memory name, bytes memory args) internal returns (address m) {
        bytes memory init =
            abi.encodePacked(vm.getCode(string.concat("contracts/v2/modules/", name, ".sol:", name)), args);
        assembly ("memory-safe") {
            m := create(0, add(init, 0x20), mload(init))
        }
        require(m != address(0) && m.code.length > 0, "module deploy failed");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
