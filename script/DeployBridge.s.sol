// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StockEscrow} from "../contracts/bridge/StockEscrow.sol";
import {StockGateway} from "../contracts/bridge/StockGateway.sol";
import {BridgedStock} from "../contracts/bridge/BridgedStock.sol";

/// Deploys the AvaxHook stock bridge, one side per run:
///
///   forge script script/DeployBridge.s.sol --sig "escrow()"  --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast
///   forge script script/DeployBridge.s.sol --sig "gateway()" --rpc-url avalanche --broadcast
///   then on each side: setRemote(<other side>)  (or pass REMOTE=… when deploying the second one)
///
/// Env: ADMIN_PRIVATE_KEY (deployer; configures, then hands ownership to OWNER),
///      VALIDATORS (comma-separated, any order), THRESHOLD (majority), GUARDIAN,
///      OWNER (multisig behind a timelock; accepts ownership afterwards; required unless
///      ALLOW_EOA_OWNER=true for local demos), REMOTE (optional),
///      DAILY_LIMIT (whole shares per stock per day, default 500), or DAILY_LIMITS (comma-separated
///      per-stock limits in share wei, in the order of `stocks()`; script/bridge-ops.mjs `limits`
///      prints them from a USD budget, e.g. $200/day/stock). Both sides must get the same limits.
contract DeployBridge is Script {
    uint256 constant AVALANCHE = 43114;
    uint256 constant ROBINHOOD = 4663;

    struct Stock {
        address origin;
        string name;
        string symbol;
    }

    /// Official Robinhood stock tokens on Robinhood Chain (verified on-chain, 18 decimals).
    function stocks() internal pure returns (Stock[] memory s) {
        s = new Stock[](8);
        s[0] = Stock(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, "NVIDIA (AvaxHook bridged)", "mNVDA");
        s[1] = Stock(0x322F0929c4625eD5bAd873c95208D54E1c003b2d, "Tesla (AvaxHook bridged)", "mTSLA");
        s[2] = Stock(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, "Apple (AvaxHook bridged)", "mAAPL");
        s[3] = Stock(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, "SPDR S&P 500 ETF (AvaxHook bridged)", "mSPY");
        s[4] = Stock(0x12f190a9F9d7D37a250758b26824B97CE941bF54, "Amazon (AvaxHook bridged)", "mAMZN");
        s[5] = Stock(0xe93237C50D904957Cf27E7B1133b510C669c2e74, "Microsoft (AvaxHook bridged)", "mMSFT");
        s[6] = Stock(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, "Alphabet (AvaxHook bridged)", "mGOOGL");
        s[7] = Stock(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, "Meta (AvaxHook bridged)", "mMETA");
    }

    function escrow() external {
        require(block.chainid == ROBINHOOD, "run on Robinhood Chain");
        (uint256 pk, address deployer) = _key();
        Stock[] memory s = stocks();
        uint128[] memory limit = _limits(s.length);

        vm.startBroadcast(pk);
        StockEscrow e = new StockEscrow(deployer, AVALANCHE);
        _configure(address(e));
        for (uint256 i; i < s.length; ++i) {
            e.setSupported(s[i].origin, true);
            e.setLimit(s[i].origin, limit[i]);
        }
        _handOver(address(e));
        vm.stopBroadcast();
        console2.log("StockEscrow", address(e));
    }

    function gateway() external {
        require(block.chainid == AVALANCHE, "run on Avalanche");
        (uint256 pk, address deployer) = _key();
        Stock[] memory s = stocks();
        uint128[] memory limit = _limits(s.length);

        vm.startBroadcast(pk);
        StockGateway g = new StockGateway(deployer, ROBINHOOD);
        _configure(address(g));
        for (uint256 i; i < s.length; ++i) {
            BridgedStock t = g.createStock(s[i].origin, s[i].name, s[i].symbol);
            g.setLimit(s[i].origin, limit[i]);
            console2.log(s[i].symbol, address(t));
        }
        _handOver(address(g));
        vm.stopBroadcast();
        console2.log("StockGateway", address(g));
    }

    /// Per-stock daily limits in share wei: DAILY_LIMITS (one per stock) or DAILY_LIMIT whole shares for all.
    function _limits(uint256 n) internal view returns (uint128[] memory l) {
        l = new uint128[](n);
        uint256[] memory each = vm.envOr("DAILY_LIMITS", ",", new uint256[](0));
        if (each.length != 0) {
            require(each.length == n, "DAILY_LIMITS needs one value per stock");
            for (uint256 i; i < n; ++i) {
                require(each[i] != 0, "DAILY_LIMITS: zero limit");
                l[i] = uint128(each[i]);
            }
        } else {
            uint128 all = uint128(vm.envOr("DAILY_LIMIT", uint256(500)) * 1e18);
            for (uint256 i; i < n; ++i) l[i] = all;
        }
        for (uint256 i; i < n; ++i) console2.log("daily limit (share wei)", stocks()[i].symbol, l[i]);
    }

    function _key() internal view returns (uint256 pk, address deployer) {
        pk = vm.envUint("ADMIN_PRIVATE_KEY");
        deployer = vm.addr(pk);
    }

    function _configure(address bridge) internal {
        address[] memory v = vm.envAddress("VALIDATORS", ",");
        // contract requires strictly ascending addresses
        for (uint256 i; i < v.length; ++i)
            for (uint256 j = i + 1; j < v.length; ++j)
                if (v[j] < v[i]) (v[i], v[j]) = (v[j], v[i]);
        StockEscrow(bridge).setValidators(v, vm.envUint("THRESHOLD"));
        StockEscrow(bridge).setGuardian(vm.envAddress("GUARDIAN"));
        address remote = vm.envOr("REMOTE", address(0));
        if (remote != address(0)) StockEscrow(bridge).setRemote(remote);
    }

    /// Ownable2Step: the multisig must call acceptOwnership() to take over.
    function _handOver(address bridge) internal {
        address owner = vm.envOr("OWNER", address(0));
        // On a real network the bridge always goes to a contract (multisig/timelock): ALLOW_EOA_OWNER
        // is honoured only on a local anvil node, even if it leaks into a mainnet shell's env.
        if (!_isAnvil()) require(owner.code.length != 0, "bridge OWNER must be a multisig/timelock contract");
        if (owner == address(0)) {
            // Production must hand the bridge to a multisig behind a timelock. Local demos opt out.
            require(vm.envOr("ALLOW_EOA_OWNER", false), "set OWNER (multisig/timelock) or ALLOW_EOA_OWNER=true");
            console2.log("WARNING: bridge stays owned by the deployer EOA");
            return;
        }
        StockEscrow(bridge).transferOwnership(owner);
        console2.log("ownership offered to", owner, "- it must call acceptOwnership()");
    }

    /// @dev True on a local anvil node (the demo forks keep the real chain ids 43114 / 4663).
    function _isAnvil() internal returns (bool) {
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory info) {
            return info.length != 0;
        } catch {
            return false;
        }
    }
}
