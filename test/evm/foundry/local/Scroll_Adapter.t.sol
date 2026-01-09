// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Scroll_Adapter } from "../../../../contracts/chain-adapters/Scroll_Adapter.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

// Mocks
import { MockScrollL1Messenger, MockScrollL1GasPriceOracle, MockScrollL1GatewayRouter } from "../../../../contracts/test/ScrollMocks.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Scroll interfaces
import { IL1GatewayRouter } from "@scroll-tech/contracts/L1/gateways/IL1GatewayRouter.sol";
import { IL1ScrollMessenger } from "@scroll-tech/contracts/L1/IL1ScrollMessenger.sol";
import { IL2GasPriceOracle } from "@scroll-tech/contracts/L1/rollup/IL2GasPriceOracle.sol";

/**
 * @title Scroll_AdapterTest
 * @notice Foundry tests for Scroll_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/Scroll_Adapter.ts
 * Tests migrated:
 *   1. relayMessage fails when there's not enough fees
 *   2. relayMessage calls spoke pool functions
 *   3. Correctly calls appropriate scroll bridge functions when transferring tokens to different chains
 */
contract Scroll_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Scroll_Adapter adapter;
    MockScrollL1Messenger l1Messenger;
    MockScrollL1GasPriceOracle l1GasPriceOracle;
    MockScrollL1GatewayRouter l1GatewayRouter;
    MockSpokePool mockSpoke;

    // ============ Chain Constants ============

    uint256 constant SCROLL_CHAIN_ID = 534351; // Scroll Sepolia (matches Hardhat test)
    uint32 constant L2_MESSAGE_GAS_LIMIT = 2_000_000;
    uint32 constant L2_TOKEN_GAS_LIMIT = 250_000;

    // ============ Test Amounts ============

    uint256 constant TOKENS_TO_SEND = 100 ether;
    uint256 constant LP_FEES = 10 ether;
    uint256 constant MOCKED_RELAYER_FEE = 10_000;

    // ============ Mock Relayer Refund Root ============

    bytes32 constant MOCK_TREE_ROOT = keccak256("mockTreeRoot");
    bytes32 constant MOCK_RELAYER_REFUND_ROOT = keccak256("mockRelayerRefundRoot");
    bytes32 constant MOCK_SLOW_RELAY_ROOT = keccak256("mockSlowRelayRoot");

    // ============ Setup ============

    function setUp() public {
        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Deploy MockSpokePool using existing mock from contracts/test/
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(fixture.weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, address(this), address(fixture.hubPool)))
        );
        mockSpoke = MockSpokePool(payable(proxy));

        // Deploy Scroll bridge mocks
        l1Messenger = new MockScrollL1Messenger();
        l1GasPriceOracle = new MockScrollL1GasPriceOracle();
        l1GatewayRouter = new MockScrollL1GatewayRouter();

        // Configure L2 token mappings on gateway router
        l1GatewayRouter.setL2ERC20Address(address(fixture.dai), fixture.l2Dai);
        l1GatewayRouter.setL2ERC20Address(address(fixture.weth), fixture.l2Weth);

        // Deploy Scroll_Adapter
        adapter = new Scroll_Adapter(
            IL1GatewayRouter(address(l1GatewayRouter)),
            IL1ScrollMessenger(address(l1Messenger)),
            IL2GasPriceOracle(address(l1GasPriceOracle)),
            L2_MESSAGE_GAS_LIMIT,
            L2_TOKEN_GAS_LIMIT
        );

        // Configure HubPool with adapter and mock spoke
        fixture.hubPool.setCrossChainContracts(SCROLL_CHAIN_ID, address(adapter), address(mockSpoke));

        // Set pool rebalance routes
        fixture.hubPool.setPoolRebalanceRoute(SCROLL_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        fixture.hubPool.setPoolRebalanceRoute(SCROLL_CHAIN_ID, address(fixture.dai), fixture.l2Dai);

        // Enable tokens for LP
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage fails when there's not enough fees
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction reverts when the gas price oracle
     *      returns a fee higher than the HubPool's ETH balance.
     */
    function test_relayMessage_RevertsWhenInsufficientFees() public {
        // Set the mocked relayer fee to be higher than HubPool's balance
        // HubPool is funded with LP_ETH_FUNDING (10 ether) in the fixture
        uint256 excessiveFee = LP_ETH_FUNDING + 1;
        l1GasPriceOracle.setMockedFee(excessiveFee);

        // Encode a mock setCrossDomainAdmin function call
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Execute should revert (HubPool wraps the revert from adapter)
        // Note: In delegatecall context, error data may not propagate cleanly, so we just verify it reverts
        vm.expectRevert();
        fixture.hubPool.relaySpokePoolAdminFunction(SCROLL_CHAIN_ID, functionCallData);
    }

    /**
     * @notice Test: relayMessage calls spoke pool functions
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction properly calls through
     *      Scroll_Adapter to send a message via L1ScrollMessenger with correct parameters
     *      and correct fee payment from the gas price oracle.
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        // Set a mocked relayer fee
        l1GasPriceOracle.setMockedFee(MOCKED_RELAYER_FEE);

        // Encode a mock setCrossDomainAdmin function call
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Record balances before
        uint256 messengerBalanceBefore = address(l1Messenger).balance;

        // Execute relay
        fixture.hubPool.relaySpokePoolAdminFunction(SCROLL_CHAIN_ID, functionCallData);

        // Verify sendMessage was called once
        assertEq(l1Messenger.sendMessageCallCount(), 1, "sendMessage should be called once");

        // Verify ETH was transferred to the messenger for fees
        assertEq(
            address(l1Messenger).balance,
            messengerBalanceBefore + MOCKED_RELAYER_FEE,
            "Messenger should receive relayer fee"
        );

        // Verify call parameters
        (address target, uint256 value, bytes memory message, uint256 gasLimit, uint256 ethValue) = l1Messenger
            .lastSendMessageCall();
        assertEq(target, address(mockSpoke), "Target should be mockSpoke");
        assertEq(value, 0, "Value should be 0 (no ETH to target)");
        assertEq(message, functionCallData, "Message should match functionCallData");
        assertEq(gasLimit, L2_MESSAGE_GAS_LIMIT, "Gas limit should be 2M");
        assertEq(ethValue, MOCKED_RELAYER_FEE, "ETH value should match relayer fee");
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly calls appropriate scroll bridge functions when transferring tokens to different chains
     * @dev Verifies that executing a root bundle properly bridges DAI via the L1 Gateway Router.
     */
    function test_relayTokens_BridgesTokensViaGatewayRouter() public {
        // Set a mocked relayer fee
        l1GasPriceOracle.setMockedFee(MOCKED_RELAYER_FEE);

        // Add liquidity for DAI
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree with single DAI leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            SCROLL_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        // Propose root bundle and advance past liveness
        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // Record balances before
        uint256 messengerBalanceBefore = address(l1Messenger).balance;

        // Execute root bundle
        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );

        // Verify depositERC20 was called once
        assertEq(l1GatewayRouter.depositERC20CallCount(), 1, "depositERC20 should be called once");

        // Verify sendMessage was also called once (for relayRootBundle)
        assertEq(l1Messenger.sendMessageCallCount(), 1, "sendMessage should be called once for relayRootBundle");

        // Verify ETH was transferred to the messenger for fees (for the relayRootBundle message)
        assertEq(
            address(l1Messenger).balance,
            messengerBalanceBefore + MOCKED_RELAYER_FEE,
            "Messenger should receive relayer fee"
        );

        // Verify depositERC20 parameters
        (address token, address to, uint256 amount, uint256 gasLimit, uint256 ethValue) = l1GatewayRouter
            .lastDepositERC20Call();
        assertEq(token, address(fixture.dai), "Token should be DAI");
        assertEq(to, address(mockSpoke), "Recipient should be mockSpoke");
        assertEq(amount, TOKENS_TO_SEND, "Amount should match");
        assertEq(gasLimit, L2_TOKEN_GAS_LIMIT, "Gas limit should be 250k");
        assertEq(ethValue, MOCKED_RELAYER_FEE, "ETH value should match relayer fee");
    }
}
