// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { deployRoutePolicy } from "../utils/RoutePolicyTestHelper.sol";

/// @notice V2 implementation used to exercise the UUPS upgrade path. Storage layout is compatible
///         with V1 (same ERC-7201 namespaced slot, same single `root` field) plus a sentinel that
///         lets us prove the new implementation is live.
contract RoutePolicyV2 is RoutePolicy {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract RoutePolicyTest is Test {
    RoutePolicy public policy;

    address public owner;
    address public other;
    bytes32 public constant INITIAL_ROOT = bytes32(uint256(0xABCD));

    function setUp() public {
        owner = makeAddr("owner");
        other = makeAddr("other");
        policy = deployRoutePolicy(owner, INITIAL_ROOT);
    }

    // --- Initialization ---

    function testInitialOwner() public view {
        assertEq(policy.owner(), owner);
    }

    function testInitialRoot() public view {
        assertEq(policy.activeRoot(address(0)), INITIAL_ROOT);
    }

    function testInitialRootCanBeZero() public {
        RoutePolicy fresh = deployRoutePolicy(owner, bytes32(0));
        assertEq(fresh.activeRoot(address(0)), bytes32(0));
    }

    function testActiveRootIgnoresCloneArgument() public {
        // V1: a single root authorizes every clone bound to this policy.
        assertEq(policy.activeRoot(address(0)), INITIAL_ROOT);
        assertEq(policy.activeRoot(address(this)), INITIAL_ROOT);
        assertEq(policy.activeRoot(makeAddr("cloneA")), INITIAL_ROOT);
        assertEq(policy.activeRoot(makeAddr("cloneB")), INITIAL_ROOT);
    }

    function testCannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        policy.initialize(other, bytes32(uint256(0x1234)));
    }

    function testImplementationCannotBeInitialized() public {
        RoutePolicy impl = new RoutePolicy();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner, INITIAL_ROOT);
    }

    // --- updateRoot ---

    function testOwnerCanUpdateRoot() public {
        bytes32 newRoot = keccak256("new-root");

        vm.expectEmit(false, false, false, true);
        emit RoutePolicy.RootUpdated(newRoot);

        vm.prank(owner);
        policy.updateRoot(newRoot);

        assertEq(policy.activeRoot(address(0)), newRoot);
    }

    function testNonOwnerCannotUpdateRoot() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.updateRoot(keccak256("malicious"));
    }

    function testUpdateRootToZero() public {
        vm.prank(owner);
        policy.updateRoot(bytes32(0));
        assertEq(policy.activeRoot(address(0)), bytes32(0));
    }

    function testRepeatedUpdates() public {
        bytes32 r1 = keccak256("r1");
        bytes32 r2 = keccak256("r2");
        bytes32 r3 = keccak256("r3");

        vm.startPrank(owner);
        policy.updateRoot(r1);
        assertEq(policy.activeRoot(address(0)), r1);
        policy.updateRoot(r2);
        assertEq(policy.activeRoot(address(0)), r2);
        policy.updateRoot(r3);
        assertEq(policy.activeRoot(address(0)), r3);
        vm.stopPrank();
    }

    // --- Ownership transfer ---

    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        policy.transferOwnership(newOwner);

        assertEq(policy.owner(), newOwner);

        bytes32 newRoot = keccak256("after-transfer");
        vm.prank(newOwner);
        policy.updateRoot(newRoot);
        assertEq(policy.activeRoot(address(0)), newRoot);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        policy.updateRoot(keccak256("old-owner-attempt"));
    }

    function testNonOwnerCannotTransferOwnership() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.transferOwnership(other);
    }

    // --- UUPS upgrade ---

    function testOwnerCanUpgrade() public {
        // Seed some state so we can verify it survives the upgrade.
        bytes32 root = keccak256("pre-upgrade");
        vm.prank(owner);
        policy.updateRoot(root);

        address newImpl = address(new RoutePolicyV2());

        vm.prank(owner);
        policy.upgradeToAndCall(newImpl, "");

        // Existing state preserved (ERC-7201 namespaced storage).
        assertEq(policy.owner(), owner);
        assertEq(policy.activeRoot(address(0)), root);

        // New implementation is live.
        assertEq(RoutePolicyV2(address(policy)).version(), "v2");

        // Owner can still update the root through the new impl.
        bytes32 postRoot = keccak256("post-upgrade");
        vm.prank(owner);
        policy.updateRoot(postRoot);
        assertEq(policy.activeRoot(address(0)), postRoot);
    }

    function testNonOwnerCannotUpgrade() public {
        address newImpl = address(new RoutePolicyV2());
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.upgradeToAndCall(newImpl, "");
    }

    // --- Cross-chain address consistency ---

    function testIdenticalProxyArgsProduceIdenticalAddress() public {
        bytes32 salt = keccak256("policy-salt");
        address impl = address(new RoutePolicy());
        bytes memory initData = abi.encodeCall(RoutePolicy.initialize, (owner, INITIAL_ROOT));
        bytes memory creationCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));
        bytes32 codeHash = keccak256(creationCode);

        // Same impl + same init data → identical predicted proxy address from a given deployer.
        address predicted1 = computeCreate2Address(salt, codeHash, address(this));
        address predicted2 = computeCreate2Address(salt, codeHash, address(this));
        assertEq(predicted1, predicted2);

        // Changing the initial root changes the init data, which changes the predicted address.
        bytes memory differentInit = abi.encodeCall(RoutePolicy.initialize, (owner, keccak256("different-root")));
        bytes memory differentCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, differentInit));
        address predicted3 = computeCreate2Address(salt, keccak256(differentCode), address(this));
        assertTrue(predicted3 != predicted1);
    }
}
