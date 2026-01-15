// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../../utils/HubPoolTestBase.sol";

// Contract under test
import { Arbitrum_SendTokensAdapter, ArbitrumL1ERC20GatewayLike } from "../../../../../contracts/chain-adapters/Arbitrum_SendTokensAdapter.sol";

// Existing mocks
import { ArbitrumMockErc20GatewayRouter } from "../../../../../contracts/test/ArbitrumMocks.sol";

/**
 * @title Arbitrum_SendTokensAdapterTest
 * @notice Foundry tests for Arbitrum_SendTokensAdapter, ported from Hardhat tests.
 * @dev Tests the emergency adapter that sends tokens from HubPool to SpokePool.
 */
contract Arbitrum_SendTokensAdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Arbitrum_SendTokensAdapter adapter;

    // ============ Mocks ============

    ArbitrumMockErc20GatewayRouter gatewayRouter;

    // ============ Addresses ============

    address refundAddress;
    address mockSpoke;
    address gateway;

    // ============ Chain Constants ============

    uint256 constant ARBITRUM_CHAIN_ID = 42161;

    // ============ Test Amounts ============

    uint256 constant AMOUNT_TO_LP = 1000 ether;

    // ============ Setup ============

    function setUp() public {
        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Create test addresses
        refundAddress = makeAddr("refundAddress");
        mockSpoke = makeAddr("mockSpoke");
        gateway = makeAddr("gateway");

        // Mint WETH to this contract and transfer to HubPool directly
        // (simulating tokens already in HubPool that need to be sent to L2)
        vm.deal(address(this), AMOUNT_TO_LP);
        fixture.weth.deposit{ value: AMOUNT_TO_LP }();
        fixture.weth.transfer(address(fixture.hubPool), AMOUNT_TO_LP);

        // Deploy Arbitrum gateway router mock with custom gateway
        gatewayRouter = new ArbitrumMockErc20GatewayRouter();
        gatewayRouter.setGateway(gateway);

        // Deploy Arbitrum_SendTokensAdapter
        adapter = new Arbitrum_SendTokensAdapter(ArbitrumL1ERC20GatewayLike(address(gatewayRouter)), refundAddress);

        // Configure HubPool with adapter and spoke pool
        fixture.hubPool.setCrossChainContracts(ARBITRUM_CHAIN_ID, address(adapter), mockSpoke);
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test that relayMessage sends desired ERC20 in specified amount to SpokePool
     * @dev Corresponds to Hardhat test: "relayMessage sends desired ERC20 in specified amount to SpokePool"
     */
    function test_relayMessage_SendsDesiredERC20InSpecifiedAmountToSpokePool() public {
        uint256 tokensToSendToL2 = AMOUNT_TO_LP;

        // Encode message as (token, amount)
        bytes memory message = abi.encode(address(fixture.weth), tokensToSendToL2);

        // Expected data passed to gateway
        bytes memory expectedData = abi.encode(adapter.l2MaxSubmissionCost(), "");

        // Expected ETH value sent to gateway
        uint256 expectedEthValue = adapter.l2MaxSubmissionCost() +
            adapter.l2GasPrice() *
            adapter.RELAY_TOKENS_L2_GAS_LIMIT();

        // Expect OutboundTransferCustomRefundCalled event
        vm.expectEmit(true, true, true, true, address(gatewayRouter));
        emit ArbitrumMockErc20GatewayRouter.OutboundTransferCustomRefundCalled(
            address(fixture.weth),
            refundAddress,
            mockSpoke,
            tokensToSendToL2,
            adapter.RELAY_TOKENS_L2_GAS_LIMIT(),
            adapter.l2GasPrice(),
            expectedData
        );

        // Record gateway router balance before
        uint256 gatewayRouterBalanceBefore = address(gatewayRouter).balance;

        // Execute relayMessage via HubPool
        fixture.hubPool.relaySpokePoolAdminFunction(ARBITRUM_CHAIN_ID, message);

        // Verify ETH was sent to gateway router
        uint256 gatewayRouterBalanceAfter = address(gatewayRouter).balance;
        assertEq(
            gatewayRouterBalanceAfter - gatewayRouterBalanceBefore,
            expectedEthValue,
            "Gateway router balance change mismatch"
        );

        // Verify WETH allowance was set on gateway (not router)
        assertEq(
            fixture.weth.allowance(address(fixture.hubPool), gateway),
            tokensToSendToL2,
            "Gateway allowance mismatch"
        );
    }
}
