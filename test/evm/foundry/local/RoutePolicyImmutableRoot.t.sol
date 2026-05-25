// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { RoutePolicyImmutableRoot } from "../../../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";
import { deployRoutePolicy, rotateRoot } from "../utils/RoutePolicyTestHelper.sol";

contract RoutePolicyImmutableRootTest is Test {
    RoutePolicyImmutableRoot public policy;

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
        RoutePolicyImmutableRoot fresh = deployRoutePolicy(owner, bytes32(0));
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
        policy.initialize(other);
    }

    function testImplementationCannotBeInitialized() public {
        RoutePolicyImmutableRoot impl = new RoutePolicyImmutableRoot(INITIAL_ROOT);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    // --- Root rotation via UUPS upgrade ---

    function testOwnerCanRotateRoot() public {
        bytes32 newRoot = keccak256("new-root");
        rotateRoot(policy, owner, newRoot);

        assertEq(policy.activeRoot(address(0)), newRoot);
        assertEq(policy.owner(), owner);
    }

    function testNonOwnerCannotRotateRoot() public {
        // Rotation == upgrade == owner-gated. Pranking a non-owner should revert at _authorizeUpgrade.
        RoutePolicyImmutableRoot newImpl = new RoutePolicyImmutableRoot(keccak256("malicious"));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.upgradeToAndCall(address(newImpl), "");
    }

    function testRotateToZeroRoot() public {
        rotateRoot(policy, owner, bytes32(0));
        assertEq(policy.activeRoot(address(0)), bytes32(0));
    }

    function testRepeatedRotations() public {
        bytes32 r1 = keccak256("r1");
        bytes32 r2 = keccak256("r2");
        bytes32 r3 = keccak256("r3");

        rotateRoot(policy, owner, r1);
        assertEq(policy.activeRoot(address(0)), r1);
        rotateRoot(policy, owner, r2);
        assertEq(policy.activeRoot(address(0)), r2);
        rotateRoot(policy, owner, r3);
        assertEq(policy.activeRoot(address(0)), r3);
    }

    function testProxyAddressIsStableAcrossRotations() public {
        address before = address(policy);
        rotateRoot(policy, owner, keccak256("r1"));
        rotateRoot(policy, owner, keccak256("r2"));
        rotateRoot(policy, owner, keccak256("r3"));
        assertEq(address(policy), before);
    }

    function testOwnershipSurvivesRotation() public {
        rotateRoot(policy, owner, keccak256("r1"));
        assertEq(policy.owner(), owner);
    }

    // --- Ownership transfer ---

    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        policy.transferOwnership(newOwner);

        assertEq(policy.owner(), newOwner);

        // New owner can rotate.
        bytes32 newRoot = keccak256("after-transfer");
        rotateRoot(policy, newOwner, newRoot);
        assertEq(policy.activeRoot(address(0)), newRoot);

        // Old owner can no longer rotate.
        RoutePolicyImmutableRoot stranded = new RoutePolicyImmutableRoot(keccak256("old-owner-attempt"));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        policy.upgradeToAndCall(address(stranded), "");
    }

    function testNonOwnerCannotTransferOwnership() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.transferOwnership(other);
    }

    // --- Cross-chain address consistency ---

    function testIdenticalDay0ArgsProduceIdenticalProxyAddress() public {
        bytes32 salt = keccak256("policy-salt");
        bytes32 initialRoot = bytes32(0); // day-0 sentinel — must be identical across chains

        // Step 1: identical impl creationCode across "chains" (same constructor arg).
        bytes memory implCode = abi.encodePacked(type(RoutePolicyImmutableRoot).creationCode, abi.encode(initialRoot));
        bytes32 implCodeHash = keccak256(implCode);

        // From a single deployer with a single salt, the impl address is determined.
        address implPredicted1 = computeCreate2Address(salt, implCodeHash, address(this));
        address implPredicted2 = computeCreate2Address(salt, implCodeHash, address(this));
        assertEq(implPredicted1, implPredicted2);

        // Step 2: proxy initCode references the impl address — same impl → same proxy address.
        bytes memory initData = abi.encodeCall(RoutePolicyImmutableRoot.initialize, (owner));
        bytes memory proxyCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(implPredicted1, initData)
        );
        address proxyPredicted1 = computeCreate2Address(salt, keccak256(proxyCode), address(this));
        address proxyPredicted2 = computeCreate2Address(salt, keccak256(proxyCode), address(this));
        assertEq(proxyPredicted1, proxyPredicted2);

        // Step 3: changing the initial root changes the impl bytecode, which changes the impl
        // address and therefore the proxy address. Day-0 root must be identical across chains.
        bytes memory differentImpl = abi.encodePacked(
            type(RoutePolicyImmutableRoot).creationCode,
            abi.encode(keccak256("different-root"))
        );
        address differentImplAddr = computeCreate2Address(salt, keccak256(differentImpl), address(this));
        bytes memory differentProxy = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(differentImplAddr, initData)
        );
        address differentProxyAddr = computeCreate2Address(salt, keccak256(differentProxy), address(this));
        assertTrue(differentProxyAddr != proxyPredicted1);
    }
}
