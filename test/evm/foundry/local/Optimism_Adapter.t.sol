// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Optimism_Adapter } from "../../../../contracts/chain-adapters/Optimism_Adapter.sol";
import { AdapterInterface } from "../../../../contracts/chain-adapters/interfaces/AdapterInterface.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { CircleDomainIds } from "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";

// Mocks
import { MockBedrockL1StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../contracts/test/MockBedrockStandardBridge.sol";
import { MockCCTPMinter, MockCCTPMessenger } from "../../../../contracts/test/MockCCTP.sol";
import { ITokenMessenger } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

/**
 * @title Optimism_AdapterTest
 * @notice Foundry tests for Optimism_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/Optimism_Adapter.ts
 * Tests migrated:
 *   1. relayMessage calls spoke pool functions
 *   2. Correctly calls appropriate Optimism bridge functions when making ERC20 cross chain calls
 *   3. Correctly unwraps WETH and bridges ETH
 *   4. Correctly calls the CCTP bridge adapter when attempting to bridge USDC
 */
contract Optimism_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Optimism_Adapter adapter;
    MockBedrockL1StandardBridge l1StandardBridge;
    MockBedrockCrossDomainMessenger l1CrossDomainMessenger;
    MockCCTPMinter cctpMinter;
    MockCCTPMessenger cctpMessenger;
    MockSpokePool mockSpoke;

    // ============ Chain Constants ============

    uint256 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant L2_GAS = 200_000;

    // ============ Test Amounts ============

    uint256 constant TOKENS_TO_SEND = 100 ether;
    uint256 constant LP_FEES = 10 ether;
    uint256 constant USDC_TO_SEND = 100e6; // USDC has 6 decimals
    uint256 constant USDC_LP_FEES = 10e6;
    uint256 constant BURN_LIMIT = 1_000_000e6; // 1M USDC per message

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

        // Deploy Optimism bridge mocks
        l1StandardBridge = new MockBedrockL1StandardBridge();
        l1CrossDomainMessenger = new MockBedrockCrossDomainMessenger();

        // Deploy CCTP mocks
        cctpMinter = new MockCCTPMinter();
        cctpMinter.setBurnLimit(BURN_LIMIT);
        cctpMessenger = new MockCCTPMessenger(cctpMinter);

        // Deploy Optimism_Adapter
        adapter = new Optimism_Adapter(
            WETH9Interface(address(fixture.weth)),
            address(l1CrossDomainMessenger),
            IL1StandardBridge(address(l1StandardBridge)),
            fixture.usdc,
            ITokenMessenger(address(cctpMessenger))
        );

        // Configure HubPool with adapter and mock spoke
        fixture.hubPool.setCrossChainContracts(OPTIMISM_CHAIN_ID, address(adapter), address(mockSpoke));

        // Set pool rebalance routes
        fixture.hubPool.setPoolRebalanceRoute(OPTIMISM_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        fixture.hubPool.setPoolRebalanceRoute(OPTIMISM_CHAIN_ID, address(fixture.dai), fixture.l2Dai);
        fixture.hubPool.setPoolRebalanceRoute(OPTIMISM_CHAIN_ID, address(fixture.usdc), fixture.l2Usdc);

        // Enable tokens for LP
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.usdc));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage calls spoke pool functions
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction properly calls through
     *      Optimism_Adapter to send a message via CrossDomainMessenger.
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        // Encode a mock setCrossDomainAdmin function call
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Execute relay
        fixture.hubPool.relaySpokePoolAdminFunction(OPTIMISM_CHAIN_ID, functionCallData);

        // Verify sendMessage was called once
        assertEq(l1CrossDomainMessenger.sendMessageCallCount(), 1, "sendMessage should be called once");

        // Verify call parameters (similar to smock's calledWith)
        (address target, bytes memory message, uint32 l2Gas) = l1CrossDomainMessenger.lastSendMessageCall();
        assertEq(target, address(mockSpoke), "Target should be mockSpoke");
        assertEq(message, functionCallData, "Message should match functionCallData");
        assertEq(l2Gas, L2_GAS, "L2 gas should be 200000");
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly calls appropriate Optimism bridge functions when making ERC20 cross chain calls
     * @dev Verifies that executing a root bundle properly bridges DAI via the standard bridge.
     */
    function test_relayTokens_BridgesERC20ViaStandardBridge() public {
        // Add liquidity for DAI
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree with single DAI leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            OPTIMISM_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        // Propose root bundle and advance past liveness
        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

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

        // Verify correct functions were called
        assertEq(l1StandardBridge.depositERC20ToCallCount(), 1, "depositERC20To should be called once");
        assertEq(l1StandardBridge.depositETHToCallCount(), 0, "depositETHTo should not be called");
        assertEq(l1CrossDomainMessenger.sendMessageCallCount(), 1, "sendMessage should be called once");

        // Verify depositERC20To parameters (similar to smock's calledWith)
        (
            address l1Token,
            address l2Token,
            address to,
            uint256 amount,
            uint32 l2Gas,
            bytes memory data
        ) = l1StandardBridge.lastDepositERC20ToCall();
        assertEq(l1Token, address(fixture.dai), "L1 token should be DAI");
        assertEq(l2Token, fixture.l2Dai, "L2 token should be l2Dai");
        assertEq(to, address(mockSpoke), "Recipient should be mockSpoke");
        assertEq(amount, TOKENS_TO_SEND, "Amount should match");
        assertEq(l2Gas, L2_GAS, "L2 gas should be 200000");
        assertEq(data, "", "Data should be empty");

        // Verify sendMessage parameters for relayRootBundle call
        bytes memory expectedRelayRootBundleData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_TREE_ROOT,
            MOCK_TREE_ROOT
        );
        (address msgTarget, bytes memory msgData, uint32 msgL2Gas) = l1CrossDomainMessenger.lastSendMessageCall();
        assertEq(msgTarget, address(mockSpoke), "Message target should be mockSpoke");
        assertEq(msgData, expectedRelayRootBundleData, "Message should be relayRootBundle call");
        assertEq(msgL2Gas, L2_GAS, "Message L2 gas should be 200000");
    }

    /**
     * @notice Test: Correctly unwraps WETH and bridges ETH
     * @dev Verifies that when bridging WETH, the adapter unwraps it to ETH and bridges via depositETHTo.
     */
    function test_relayTokens_UnwrapsWETHAndBridgesETH() public {
        // Add liquidity for WETH - need to deposit ETH first and ensure approval for both liquidity and bond
        uint256 wethNeeded = TOKENS_TO_SEND + BOND_AMOUNT;
        vm.deal(address(this), wethNeeded);
        fixture.weth.deposit{ value: wethNeeded }();
        fixture.weth.approve(address(fixture.hubPool), type(uint256).max);
        fixture.hubPool.addLiquidity(address(fixture.weth), TOKENS_TO_SEND);

        // Build merkle tree with single WETH leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            OPTIMISM_CHAIN_ID,
            address(fixture.weth),
            TOKENS_TO_SEND,
            LP_FEES
        );

        // Propose root bundle and advance past liveness
        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

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

        // Verify correct functions were called
        assertEq(l1StandardBridge.depositETHToCallCount(), 1, "depositETHTo should be called once");
        assertEq(l1StandardBridge.depositERC20ToCallCount(), 0, "depositERC20To should not be called");
        assertEq(l1CrossDomainMessenger.sendMessageCallCount(), 1, "sendMessage should be called once");

        // Verify depositETHTo parameters (similar to smock's calledWith)
        (address to, uint256 value, uint32 l2Gas, bytes memory data) = l1StandardBridge.lastDepositETHToCall();
        assertEq(to, address(mockSpoke), "Recipient should be mockSpoke");
        assertEq(value, TOKENS_TO_SEND, "ETH value should match tokens sent");
        assertEq(l2Gas, L2_GAS, "L2 gas should be 200000");
        assertEq(data, "", "Data should be empty");

        // Verify sendMessage parameters for relayRootBundle call
        bytes memory expectedRelayRootBundleData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_TREE_ROOT,
            MOCK_TREE_ROOT
        );
        (address msgTarget, bytes memory msgData, uint32 msgL2Gas) = l1CrossDomainMessenger.lastSendMessageCall();
        assertEq(msgTarget, address(mockSpoke), "Message target should be mockSpoke");
        assertEq(msgData, expectedRelayRootBundleData, "Message should be relayRootBundle call");
        assertEq(msgL2Gas, L2_GAS, "Message L2 gas should be 200000");
    }

    /**
     * @notice Test: Correctly calls the CCTP bridge adapter when attempting to bridge USDC
     * @dev Verifies that executing a root bundle properly bridges USDC via CCTP.
     */
    function test_relayTokens_BridgesUsdcViaCCTP() public {
        // Add liquidity for USDC
        addLiquidity(fixture.usdc, USDC_TO_SEND);

        // Build merkle tree with single USDC leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            OPTIMISM_CHAIN_ID,
            address(fixture.usdc),
            USDC_TO_SEND,
            USDC_LP_FEES
        );

        // Propose root bundle and advance past liveness
        proposeBundleAndAdvanceTime(root, MOCK_RELAYER_REFUND_ROOT, MOCK_SLOW_RELAY_ROOT);

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

        // Verify depositForBurn was called
        assertEq(cctpMessenger.depositForBurnCallCount(), 1, "depositForBurn should be called once");

        // Verify depositForBurn parameters (similar to smock's calledWith)
        (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
            .lastDepositForBurnCall();
        assertEq(amount, USDC_TO_SEND, "Amount should match");
        assertEq(destinationDomain, CircleDomainIds.Optimism, "Destination domain should be Optimism");
        assertEq(mintRecipient, bytes32(uint256(uint160(address(mockSpoke)))), "Mint recipient should be mockSpoke");
        assertEq(burnToken, address(fixture.usdc), "Burn token should be USDC");

        // Verify HubPool approved the CCTP TokenMessenger to spend USDC
        assertEq(
            fixture.usdc.allowance(address(fixture.hubPool), address(cctpMessenger)),
            USDC_TO_SEND,
            "Allowance should be set for CCTP TokenMessenger"
        );
    }
}
