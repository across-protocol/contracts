// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../../utils/HubPoolTestBase.sol";

// Contract under test
import {
    Arbitrum_RescueAdapter,
    ArbitrumL1InboxLike
} from "../../../../../contracts/chain-adapters/Arbitrum_RescueAdapter.sol";

// Existing mocks
import { Inbox } from "../../../../../contracts/test/ArbitrumMocks.sol";

/**
 * @title Arbitrum_RescueAdapterTest
 * @notice Foundry tests for Arbitrum_RescueAdapter.
 * @dev Tests the rescue adapter that recovers ETH held by the HubPool's aliased address on Arbitrum.
 */
contract Arbitrum_RescueAdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Arbitrum_RescueAdapter adapter;

    // ============ Mocks ============

    Inbox inbox;

    // ============ Addresses ============

    address l2Recipient;
    address mockSpoke;

    // ============ Chain Constants ============

    uint256 constant ARBITRUM_CHAIN_ID = 42161;
    uint256 constant AMOUNT_TO_RESCUE = 13.92e18;

    // ============ Setup ============

    function setUp() public {
        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test addresses
        l2Recipient = makeAddr("l2Recipient");
        mockSpoke = makeAddr("mockSpoke");

        // Deploy Arbitrum inbox mock and the rescue adapter pointing at it
        inbox = new Inbox();
        adapter = new Arbitrum_RescueAdapter(ArbitrumL1InboxLike(address(inbox)), l2Recipient);

        // Configure HubPool with adapter and spoke pool
        fixture.hubPool.setCrossChainContracts(ARBITRUM_CHAIN_ID, address(adapter), mockSpoke);
    }

    // ============ Constructor Tests ============

    /**
     * @notice Test that the constructor rejects a zero L2 recipient, which would burn the rescued ETH.
     */
    function test_constructor_RevertsOnZeroRecipient() public {
        vm.expectRevert(Arbitrum_RescueAdapter.InvalidL2Recipient.selector);
        new Arbitrum_RescueAdapter(ArbitrumL1InboxLike(address(inbox)), address(0));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test that relayMessage creates an unsafe retryable ticket sending the rescued amount to the recipient,
     * paying the L1 call value from the HubPool's ETH balance.
     */
    function test_relayMessage_RescuesEthToRecipient() public {
        // Fund the HubPool with the ETH required to pay for the L1 -> L2 message.
        uint256 expectedL1CallValue = adapter.l2MaxSubmissionCost() + adapter.l2GasPrice() * adapter.l2GasLimit();
        assertEq(adapter.getL1CallValue(), expectedL1CallValue, "getL1CallValue mismatch");
        fixture.hubPool.loadEthForL2Calls{ value: expectedL1CallValue }();

        // Execute relayMessage via HubPool with the amount to rescue
        fixture.hubPool.relaySpokePoolAdminFunction(ARBITRUM_CHAIN_ID, abi.encode(AMOUNT_TO_RESCUE));

        // The full L1 call value must have been forwarded to the inbox
        assertEq(address(inbox).balance, expectedL1CallValue, "Inbox balance mismatch");
        assertEq(inbox.lastUnsafeCreateRetryableTicketMsgValue(), expectedL1CallValue, "msg.value mismatch");

        // Verify unsafeCreateRetryableTicket was called exactly once with the correct arguments
        assertEq(inbox.unsafeCreateRetryableTicketCallCount(), 1, "unsafeCreateRetryableTicket should be called once");
        (
            address destAddr,
            uint256 l2CallValue,
            uint256 maxSubmissionCost,
            address excessFeeRefundAddress,
            address callValueRefundAddress,
            uint256 maxGas,
            uint256 gasPriceBid,
            bytes memory data
        ) = inbox.lastUnsafeCreateRetryableTicketCall();

        assertEq(destAddr, l2Recipient, "to mismatch");
        assertEq(l2CallValue, AMOUNT_TO_RESCUE, "l2CallValue mismatch");
        assertEq(maxSubmissionCost, adapter.l2MaxSubmissionCost(), "maxSubmissionCost mismatch");
        assertEq(excessFeeRefundAddress, l2Recipient, "excessFeeRefundAddress mismatch");
        assertEq(callValueRefundAddress, l2Recipient, "callValueRefundAddress mismatch");
        assertEq(maxGas, adapter.l2GasLimit(), "gasLimit mismatch");
        assertEq(gasPriceBid, adapter.l2GasPrice(), "maxFeePerGas mismatch");
        assertEq(data, "", "data should be empty");
    }

    /**
     * @notice Test that relayMessage reverts when the HubPool does not hold enough ETH for the L1 call value.
     * @dev The HubPool swallows the adapter's revert reason and reverts with "delegatecall failed".
     */
    function test_relayMessage_RevertsIfHubPoolLacksEth() public {
        vm.deal(address(fixture.hubPool), 0);
        vm.expectRevert("delegatecall failed");
        fixture.hubPool.relaySpokePoolAdminFunction(ARBITRUM_CHAIN_ID, abi.encode(AMOUNT_TO_RESCUE));
    }

    /**
     * @notice Test the adapter's own insufficient-balance revert reason when called directly.
     */
    function test_relayMessage_RevertsWithoutSufficientEth() public {
        vm.expectRevert("Insufficient ETH balance");
        adapter.relayMessage(mockSpoke, abi.encode(AMOUNT_TO_RESCUE));
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test that relayTokens always reverts.
     */
    function test_relayTokens_Reverts() public {
        vm.expectRevert("useless function");
        adapter.relayTokens(address(0), address(0), 0, address(0));
    }
}
