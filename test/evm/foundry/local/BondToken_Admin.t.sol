// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { BondToken, ExtendedHubPoolInterface } from "../../../../contracts/BondToken.sol";

/**
 * @title BondToken_AdminTest
 * @notice Foundry tests for BondToken admin functions.
 */
contract BondToken_AdminTest is Test {
    // ============ Events ============

    event ProposerModified(address proposer, bool enabled);

    // ============ State ============

    BondToken public bondToken;
    address public owner;
    address public other;

    // ============ Setup ============

    function setUp() public {
        owner = address(this);
        other = makeAddr("other");

        // Create a mock HubPool address (BondToken only needs its address for construction)
        address mockHubPool = makeAddr("hubPool");
        vm.etch(mockHubPool, hex"00"); // Put dummy code at the address

        bondToken = new BondToken(ExtendedHubPoolInterface(mockHubPool));
    }

    // ============ Tests ============

    function test_OwnerCanManageProposers() public {
        // Initially owner is not a proposer
        assertFalse(bondToken.proposers(owner));

        // Initially other is not a proposer
        assertFalse(bondToken.proposers(other));

        // Owner enables other as a proposer
        vm.expectEmit(true, true, true, true);
        emit ProposerModified(other, true);
        bondToken.setProposer(other, true);
        assertTrue(bondToken.proposers(other));

        // Owner disables other as a proposer
        vm.expectEmit(true, true, true, true);
        emit ProposerModified(other, false);
        bondToken.setProposer(other, false);
        assertFalse(bondToken.proposers(other));
    }

    function test_NonOwnersCannotManageProposers() public {
        assertFalse(bondToken.proposers(other));

        // Try enabling as proposer - should revert
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        bondToken.setProposer(other, true);
        assertFalse(bondToken.proposers(other));

        // Try disabling as proposer - should revert
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        bondToken.setProposer(other, false);
        assertFalse(bondToken.proposers(other));

        // Try enabling again - should revert
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        bondToken.setProposer(other, true);
        assertFalse(bondToken.proposers(other));

        // Try disabling again - should revert
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        bondToken.setProposer(other, false);
        assertFalse(bondToken.proposers(other));
    }
}
