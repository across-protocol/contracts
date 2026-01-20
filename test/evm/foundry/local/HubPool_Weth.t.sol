// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";

/**
 * @title HubPool_WethTest
 * @notice Foundry tests for HubPool ETH handling, ported from Hardhat tests.
 */
contract HubPool_WethTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    address owner;

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test accounts
        owner = address(this); // Test contract is owner
    }

    // ============ Tests ============

    function test_CorrectlyWrapsEthToWethWhenEthIsDroppedOnTheContract() public {
        // Drop ETH on the hubPool and check that hubPool wraps it.
        assertEq(fixture.weth.balanceOf(address(fixture.hubPool)), 0);

        // Drop ETH on the contract. Check it wraps it to WETH.
        (bool success, ) = address(fixture.hubPool).call{ value: 1 ether }("");
        assertTrue(success);

        assertEq(fixture.weth.balanceOf(address(fixture.hubPool)), 1 ether);
    }
}
