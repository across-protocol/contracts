// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { IRoutePolicy } from "../../../../contracts/interfaces/IRoutePolicy.sol";

contract RoutePolicyTest is Test {
    RoutePolicy public policy;

    address public owner;
    address public other;
    bytes32 public constant INITIAL_ROOT = bytes32(uint256(0xABCD));

    function setUp() public {
        owner = makeAddr("owner");
        other = makeAddr("other");
        policy = new RoutePolicy(owner, INITIAL_ROOT);
    }

    // --- Constructor ---

    function testInitialOwner() public view {
        assertEq(policy.owner(), owner);
    }

    function testInitialRoot() public view {
        assertEq(policy.activeRoot(), INITIAL_ROOT);
    }

    function testInitialRootCanBeZero() public {
        RoutePolicy fresh = new RoutePolicy(owner, bytes32(0));
        assertEq(fresh.activeRoot(), bytes32(0));
    }

    // --- updateRoot ---

    function testOwnerCanUpdateRoot() public {
        bytes32 newRoot = keccak256("new-root");

        vm.expectEmit(false, false, false, true);
        emit IRoutePolicy.RootUpdated(newRoot);

        vm.prank(owner);
        policy.updateRoot(newRoot);

        assertEq(policy.activeRoot(), newRoot);
    }

    function testNonOwnerCannotUpdateRoot() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.updateRoot(keccak256("malicious"));
    }

    function testUpdateRootToZero() public {
        vm.prank(owner);
        policy.updateRoot(bytes32(0));
        assertEq(policy.activeRoot(), bytes32(0));
    }

    function testRepeatedUpdates() public {
        bytes32 r1 = keccak256("r1");
        bytes32 r2 = keccak256("r2");
        bytes32 r3 = keccak256("r3");

        vm.startPrank(owner);
        policy.updateRoot(r1);
        assertEq(policy.activeRoot(), r1);
        policy.updateRoot(r2);
        assertEq(policy.activeRoot(), r2);
        policy.updateRoot(r3);
        assertEq(policy.activeRoot(), r3);
        vm.stopPrank();
    }

    // --- Ownership transfer ---

    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        policy.transferOwnership(newOwner);

        assertEq(policy.owner(), newOwner);

        // New owner can update root
        bytes32 newRoot = keccak256("after-transfer");
        vm.prank(newOwner);
        policy.updateRoot(newRoot);
        assertEq(policy.activeRoot(), newRoot);

        // Old owner can no longer update
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        policy.updateRoot(keccak256("old-owner-attempt"));
    }

    function testNonOwnerCannotTransferOwnership() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        policy.transferOwnership(other);
    }

    // --- Cross-chain address consistency: identical constructor args → identical address ---

    function testIdenticalArgsProduceIdenticalAddress() public {
        bytes32 salt = keccak256("policy-salt");
        bytes memory creationCode = abi.encodePacked(type(RoutePolicy).creationCode, abi.encode(owner, INITIAL_ROOT));
        bytes32 codeHash = keccak256(creationCode);

        // Compute the CREATE2 address from this test contract for two different "chains" — but since
        // the deployer and args are the same, the predicted address is identical.
        address predicted1 = computeCreate2Address(salt, codeHash, address(this));
        address predicted2 = computeCreate2Address(salt, codeHash, address(this));
        assertEq(predicted1, predicted2);

        // Now change just the initial root; the address must change.
        bytes memory differentCode = abi.encodePacked(
            type(RoutePolicy).creationCode,
            abi.encode(owner, keccak256("different-root"))
        );
        address predicted3 = computeCreate2Address(salt, keccak256(differentCode), address(this));
        assertTrue(predicted3 != predicted1);
    }
}
