// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { AcrossConfigStore } from "../../../../contracts/AcrossConfigStore.sol";

/**
 * @title ConfigStore_Test
 * @notice Foundry tests for AcrossConfigStore.
 */
contract ConfigStore_Test is Test {
    // ============ Events ============

    event UpdatedTokenConfig(address indexed key, string value);
    event UpdatedGlobalConfig(bytes32 indexed key, string value);

    // ============ Constants ============

    // Sample rate model
    string constant SAMPLE_RATE_MODEL_JSON =
        '{"rateModel":{"UBar":"800000000000000000","R0":"40000000000000000","R1":"70000000000000000","R2":"750000000000000000"},"tokenTransferThreshold":"100000000000000000000"}';

    // Global config key
    bytes32 constant MAX_POOL_REBALANCE_LEAF_SIZE_KEY = bytes32("MAX_POOL_REBALANCE_LEAF_SIZE");
    string constant MAX_REFUNDS_VALUE = "3";

    // ============ State ============

    AcrossConfigStore public configStore;
    address public owner;
    address public other;

    // ============ Setup ============

    function setUp() public {
        owner = address(this);
        other = makeAddr("other");

        configStore = new AcrossConfigStore();
    }

    // ============ Tests ============

    function test_UpdatingTokenConfig() public {
        address l1Token = makeAddr("l1Token");

        // Non-owner cannot update token config
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        configStore.updateTokenConfig(l1Token, SAMPLE_RATE_MODEL_JSON);

        // Owner can update token config
        vm.expectEmit(true, true, true, true);
        emit UpdatedTokenConfig(l1Token, SAMPLE_RATE_MODEL_JSON);
        configStore.updateTokenConfig(l1Token, SAMPLE_RATE_MODEL_JSON);

        // Verify value is stored
        assertEq(configStore.l1TokenConfig(l1Token), SAMPLE_RATE_MODEL_JSON);
    }

    function test_UpdatingGlobalConfig() public {
        // Non-owner cannot update global config
        vm.prank(other);
        vm.expectRevert("Ownable: caller is not the owner");
        configStore.updateGlobalConfig(MAX_POOL_REBALANCE_LEAF_SIZE_KEY, MAX_REFUNDS_VALUE);

        // Owner can update global config
        vm.expectEmit(true, true, true, true);
        emit UpdatedGlobalConfig(MAX_POOL_REBALANCE_LEAF_SIZE_KEY, MAX_REFUNDS_VALUE);
        configStore.updateGlobalConfig(MAX_POOL_REBALANCE_LEAF_SIZE_KEY, MAX_REFUNDS_VALUE);

        // Verify value is stored
        assertEq(configStore.globalConfig(MAX_POOL_REBALANCE_LEAF_SIZE_KEY), MAX_REFUNDS_VALUE);
    }
}
