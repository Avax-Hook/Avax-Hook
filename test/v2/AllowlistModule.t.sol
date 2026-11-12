// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookTokenV2} from "../../contracts/v2/HookTokenV2.sol";
import {ModuleCaps} from "../../contracts/v2/interfaces/IHookModule.sol";
import {AllowlistModule} from "../../contracts/v2/modules/AllowlistModule.sol";
import {ListsAccessBase} from "./ListsAccessBase.t.sol";

contract AllowlistModuleTest is ListsAccessBase {
    AllowlistModule al;
    uint32 alId;
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");
    address gina = makeAddr("gina");
    bytes32 root;
    bytes32[4] leaves;

    function setUp() public override {
        super.setUp();
        al = new AllowlistModule(address(hook));
        alId = modules.addModule(address(al), '{"name":"Allowlist"}');
        (leaves[0], leaves[1], leaves[2], leaves[3]) = (al.leaf(dave), al.leaf(erin), al.leaf(frank), al.leaf(gina));
        root = _h(_h(leaves[0], leaves[1]), _h(leaves[2], leaves[3]));
    }

    function _h(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// Proof for leaf i of the 4-leaf tree.
    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        p[1] = i < 2 ? _h(leaves[2], leaves[3]) : _h(leaves[0], leaves[1]);
    }

    /// Allowed list: the curve-filling holders + alice; plus the Merkle root.
    function _cfg(uint256 nHolders, bytes32 r, uint32 d) internal view returns (bytes memory) {
        address[] memory l = new address[](nHolders + 1);
        for (uint256 i; i < nHolders; ++i) l[i] = _holder(i);
        l[nHolders] = alice;
        return abi.encode(AllowlistModule.Config(l, r, d));
    }

    function test_capabilitiesAndBounds() public {
        assertEq(al.capabilities(), ModuleCaps.BEFORE_SWAP | ModuleCaps.ON_TRANSFER | ModuleCaps.LIQUIDITY);
        assertEq(al.conflictGroups(), ModuleCaps.GROUP_RECEIVER_LIST);
        vm.expectRevert(); // neither list nor root
        al.validateConfig(abi.encode(AllowlistModule.Config(new address[](0), bytes32(0), 0)));
        vm.expectRevert();
        al.validateConfig(abi.encode(AllowlistModule.Config(new address[](201), root, 0)));
        vm.expectRevert();
        al.validateConfig(abi.encode(AllowlistModule.Config(new address[](0), root, 365 days + 1)));
        al.validateConfig(abi.encode(AllowlistModule.Config(new address[](0), root, 0)));
        // leaf format: OZ StandardMerkleTree double hash of abi.encode(address)
        assertEq(al.leaf(dave), keccak256(bytes.concat(keccak256(abi.encode(dave)))));
    }

    function test_listOnCurve_proofViaBuyWithData() public {
        HookTokenV2 t = _launch(_one(alId), _oneCfg(_cfg(0, root, 0)), 0);
        _curveBuy(alice, t, 1 ether); // on the list
        _curveBuyReverts(bob, t, 1 ether); // not on it
        _curveBuyReverts(dave, t, 1 ether); // in the tree but no proof given
        _curveBuy(creator, t, 1 ether); // creator exempt
        // proof in the curve buy's extra marks the buyer in the same trade
        vm.deal(dave, 1 ether);
        vm.prank(dave);
        pad.buyWithData{value: 1 ether}(address(t), 1 ether, 0, address(0), abi.encode(_proof(0)));
        assertTrue(al.isAllowed(address(t), dave));
        // a wrong proof is ignored and the buy refused
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        pad.buyWithData{value: 1 ether}(address(t), 1 ether, 0, address(0), abi.encode(_proof(1)));
        // garbage extra is ignored too
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AllowlistModule.NotAllowed.selector, bob));
        pad.buyWithData{value: 1 ether}(address(t), 1 ether, 0, address(0), hex"1234");
    }

    function test_pool_proveRouterAggTransfers_expiry() public {
        HookTokenV2 t = _launch(_one(alId), _oneCfg(_cfg(120, root, 1 days)), 0);
        PoolKey memory key = _graduateN(t, 40, 0);
        _buyReverts(bob, t, 1 ether);
        uint256 got = _routerBuy(alice, t, 1 ether);
        // router buy with the proof in extra
        vm.deal(erin, 1 ether);
        vm.prank(erin);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, address(0), block.timestamp, abi.encode(_proof(1)));
        assertTrue(al.isAllowed(address(t), erin));
        // permissionless prove, then a transfer in works
        _sendReverts(t, alice, frank, got / 4);
        vm.expectRevert(AllowlistModule.BadProof.selector);
        al.prove(address(t), frank, _proof(0));
        vm.prank(bob);
        al.prove(address(t), frank, _proof(2));
        _send(t, alice, frank, got / 4);
        // aggregator contract not allowed
        vm.expectRevert();
        _aggBuy(key, 1 ether);
        // sells always work
        _routerSell(frank, t, got / 4);
        // after the window anyone receives
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(al.canReceive(address(t), bob));
        _routerBuy(bob, t, 1 ether);
        _aggBuy(key, 1 ether);
    }

    function test_listOnlyNoRoot() public {
        HookTokenV2 t = _launch(_one(alId), _oneCfg(_cfg(120, bytes32(0), 0)), 0);
        vm.expectRevert(AllowlistModule.BadProof.selector);
        al.prove(address(t), dave, _proof(0));
        _graduateN(t, 40, 0);
        vm.deal(dave, 1 ether);
        _buyReverts(dave, t, 1 ether);
        (bytes32 r, uint256 until) = al.allowlist(address(t));
        assertEq(r, bytes32(0));
        assertEq(until, type(uint256).max);
    }

    function testFuzz_proveRejectsOutsiders(address who) public {
        vm.assume(who != dave && who != erin && who != frank && who != gina);
        HookTokenV2 t = _launch(_one(alId), _oneCfg(_cfg(0, root, 0)), 0);
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(AllowlistModule.BadProof.selector);
            al.prove(address(t), who, _proof(i));
        }
    }
}
