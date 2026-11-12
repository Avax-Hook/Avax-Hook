// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignedPriceHub, HubPriceFeed} from "../../contracts/SignedPriceHub.sol";
import {SignedPriceFeed} from "../../contracts/SignedPriceFeed.sol";

contract SignedPriceHubAuditTest is Test {
    uint256 pk = 0xA11CE;
    address signerAddr;
    SignedPriceHub hub;

    function setUp() public {
        vm.warp(1_800_000_000);
        signerAddr = vm.addr(pk);
        hub = new SignedPriceHub(address(this), signerAddr);
    }

    /// The hub's hand-rolled domain equals OZ EIP712's domain for the same verifyingContract.
    function test_domainParityWithSignedPriceFeed() public {
        SignedPriceFeed f = new SignedPriceFeed(address(this), signerAddr, "x", 18, 1e18);
        (, string memory name, string memory version, uint256 chainId, address vc,,) = f.eip712Domain();
        bytes32 ozDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)), keccak256(bytes(version)), chainId, vc
            )
        );
        assertEq(hub.domainSeparator(address(f)), ozDomain);
    }

    /// A front-runner who applies a newer public signature only makes the keeper's entry skip; batch still lands.
    function test_frontRunDoesNotRevertBatch() public {
        address a = hub.createFeed("A", 1e18);
        address b = hub.createFeed("B", 1e18);
        vm.warp(block.timestamp + 60);
        uint64 t = uint64(block.timestamp);
        SignedPriceHub.Update[] memory u = new SignedPriceHub.Update[](2);
        u[0] = SignedPriceHub.Update(a, 2e18, t, _sig(a, 2e18, t));
        u[1] = SignedPriceHub.Update(b, 3e18, t, _sig(b, 3e18, t));
        HubPriceFeed(a).update(2e18, t, u[0].signature); // attacker copies entry 0 from the mempool
        assertEq(hub.updateBatch(u), 1);
    }

    /// Clones see the hub immutable from the implementation code.
    function test_cloneHubImmutable() public {
        address a = hub.createFeed("A", 1e18);
        assertEq(address(HubPriceFeed(a).hub()), address(hub));
        assertEq(HubPriceFeed(a).owner(), address(this));
        (, int256 ans,,,) = HubPriceFeed(a).latestRoundData();
        assertEq(ans, 1e18);
    }

    function _sig(address feed, int256 ans, uint64 t) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(hub.PRICE_UPDATE_TYPEHASH(), ans, t));
        bytes32 d = keccak256(abi.encodePacked("\x19\x01", hub.domainSeparator(feed), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }
}
