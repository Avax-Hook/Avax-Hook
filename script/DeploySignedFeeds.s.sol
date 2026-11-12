// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {QuoteRegistry} from "../contracts/QuoteRegistry.sol";
import {ManualPriceFeed} from "../contracts/ManualPriceFeed.sol";
import {SignedPriceFeed} from "../contracts/SignedPriceFeed.sol";

/// Replaces the keeper-pushed ManualPriceFeeds of the quote coins in script/stock-feeds.json with
/// pull-model SignedPriceFeeds, starting each at the old feed's current answer.
///
/// forge script script/DeploySignedFeeds.s.sol --rpc-url avalanche --broadcast --slow
/// Env: ADMIN_PRIVATE_KEY (deployer; must still own the QuoteRegistry),
///      REGISTRY (default: mainnet QuoteRegistry),
///      SIGNER (default: KEEPER_ADDRESS; off-chain price signer),
///      OWNER (multisig; each feed's ownership is offered to it, it must acceptOwnership()).
/// Per-quote price bounds in the registry are keyed by token, so they carry over unchanged.
/// On a broadcast run the token → feed mapping is written to script/signed-feeds.json.
contract DeploySignedFeeds is Script {
    uint256 constant AVALANCHE = 43114;
    address constant MAINNET_REGISTRY = 0xaED8702bD08FA20d6e49B09AcE6fa2E20cbF6FF1;
    string constant IN = "script/stock-feeds.json";
    string constant OUT = "script/signed-feeds.json";

    function run() external {
        uint256 pk = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin = vm.addr(pk);
        QuoteRegistry registry = QuoteRegistry(vm.envOr("REGISTRY", MAINNET_REGISTRY));
        address signer = vm.envOr("SIGNER", vm.envOr("KEEPER_ADDRESS", address(0)));
        address owner = vm.envOr("OWNER", address(0));
        require(signer != address(0), "set SIGNER or KEEPER_ADDRESS");
        if (owner == address(0) && block.chainid == AVALANCHE) {
            require(vm.envOr("ALLOW_EOA_OWNER", false), "set OWNER (multisig) or ALLOW_EOA_OWNER=true");
        }
        require(registry.owner() == admin, "admin no longer owns the registry: OWNER must call setQuote");

        string memory json = vm.readFile(IN);
        string[] memory keys = vm.parseJsonKeys(json, "$");
        string memory out = "signedFeeds";
        string memory serialized;

        vm.startBroadcast(pk);
        for (uint256 i; i < keys.length; ++i) {
            string memory base = string.concat("$['", keys[i], "']");
            address token = vm.parseJsonAddress(json, string.concat(base, ".token"));
            string memory symbol = vm.parseJsonString(json, string.concat(base, ".symbol"));
            ManualPriceFeed old = ManualPriceFeed(vm.parseJsonAddress(json, string.concat(base, ".feed")));
            (, int256 answer,,,) = old.latestRoundData();
            uint8 dec = old.decimals();

            SignedPriceFeed feed = new SignedPriceFeed(admin, signer, old.description(), dec, answer);
            registry.setQuote(token, true, address(feed));
            if (owner != address(0)) feed.transferOwnership(owner);

            string memory k = vm.toLowercase(vm.toString(token));
            vm.serializeString(k, "symbol", symbol);
            vm.serializeAddress(k, "token", token);
            vm.serializeAddress(k, "feed", address(feed));
            string memory entry = vm.serializeUint(k, "decimals", dec);
            serialized = vm.serializeString(out, k, entry);
            console2.log(symbol, token, address(feed));
        }
        vm.stopBroadcast();

        console2.log(serialized);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            vm.writeJson(serialized, OUT);
            console2.log("wrote", OUT);
        } else {
            console2.log("dry run: not writing", OUT);
        }
        if (owner != address(0)) console2.log("feed ownership offered to", owner, "- it must acceptOwnership()");
        else if (block.chainid == AVALANCHE) console2.log("WARNING: feeds stay owned by the deployer EOA", admin);
    }
}
