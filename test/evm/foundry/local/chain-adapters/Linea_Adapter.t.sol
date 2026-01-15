// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Linea_Adapter } from "../../../../contracts/chain-adapters/Linea_Adapter.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { CircleDomainIds } from "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";

// Mocks
import { MockCCTPMinter, MockCCTPMessengerV2 } from "../../../../contracts/test/MockCCTP.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { ITokenMessenger, ITokenMinter } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

// Linea interfaces
import { IMessageService, ITokenBridge } from "../../../../contracts/external/interfaces/LineaInterfaces.sol";

// Function selectors
bytes4 constant SEND_MESSAGE_SELECTOR = bytes4(keccak256("sendMessage(address,uint256,bytes)"));
bytes4 constant BRIDGE_TOKEN_SELECTOR = bytes4(keccak256("bridgeToken(address,uint256,address)"));

/**
 * @title Linea_AdapterTest
 * @notice Foundry tests for Linea_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *      Uses vm.mockCall for Linea bridge contracts and MockCCTPMessengerV2 for CCTP V2.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/Linea_Adapter.ts
 * Tests migrated:
 *   1. relayMessage calls spoke pool functions
 *   2. Correctly calls appropriate bridge functions when making ERC20 cross chain calls
 *   3. Correctly calls the CCTP bridge adapter when attempting to bridge USDC
 *   4. Splits USDC into parts to stay under per-message limit when attempting to bridge USDC
 *   5. Correctly unwraps WETH and bridges ETH
 */
contract Linea_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Linea_Adapter adapter;
    MockCCTPMinter cctpMinter;
    MockCCTPMessengerV2 cctpMessenger;
    MockSpokePool mockSpoke;

    // Fake addresses for mocked contracts (no actual code deployed)
    address lineaMessageService;
    address lineaTokenBridge;

    // ============ Chain Constants ============

    uint256 constant LINEA_CHAIN_ID = 59144;

    // ============ Setup ============

    function setUp() public {
        createHubPoolFixture();

        // Deploy MockSpokePool using helper
        mockSpoke = deployMockSpokePool(address(this));

        // Create fake addresses for the Linea bridge contracts using helper
        lineaMessageService = makeFakeContract("lineaMessageService");
        lineaTokenBridge = makeFakeContract("lineaTokenBridge");

        // Mock sendMessage to succeed by default
        vm.mockCall(lineaMessageService, abi.encodeWithSelector(SEND_MESSAGE_SELECTOR), abi.encode());

        // Mock bridgeToken to succeed by default
        vm.mockCall(lineaTokenBridge, abi.encodeWithSelector(BRIDGE_TOKEN_SELECTOR), abi.encode());

        // Deploy CCTP V2 mocks
        cctpMinter = new MockCCTPMinter();
        cctpMinter.setBurnLimit(BURN_LIMIT);
        // Pass a non-zero fee recipient so V2 detection works
        cctpMessenger = new MockCCTPMessengerV2(ITokenMinter(address(cctpMinter)), address(this));

        // Deploy Linea_Adapter
        adapter = new Linea_Adapter(
            WETH9Interface(address(fixture.weth)),
            IMessageService(lineaMessageService),
            ITokenBridge(lineaTokenBridge),
            fixture.usdc,
            ITokenMessenger(address(cctpMessenger))
        );

        // Configure HubPool
        fixture.hubPool.setCrossChainContracts(LINEA_CHAIN_ID, address(adapter), address(mockSpoke));

        // Set pool rebalance routes and enable tokens for LP
        setupTokenRoutes(LINEA_CHAIN_ID, fixture.l2Weth, fixture.l2Dai, fixture.l2Usdc);
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage calls spoke pool functions
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction properly calls through
     *      Linea_Adapter to send a message via MessageService.
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Expect the sendMessage call with specific parameters
        // Linea adapter sets fee to 0 since auto-claiming is not supported for non-empty calldata
        vm.expectCall(
            lineaMessageService,
            0, // No ETH value since fee is 0
            abi.encodeWithSelector(
                SEND_MESSAGE_SELECTOR,
                address(mockSpoke), // target
                uint256(0), // fee
                functionCallData // message
            )
        );

        fixture.hubPool.relaySpokePoolAdminFunction(LINEA_CHAIN_ID, functionCallData);
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly calls appropriate bridge functions when making ERC20 cross chain calls
     * @dev Verifies that executing a root bundle properly bridges DAI via the token bridge.
     */
    function test_relayTokens_BridgesERC20ViaTokenBridge() public {
        // Add liquidity for DAI
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree with single DAI leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            LINEA_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // Expect bridgeToken call with correct parameters
        vm.expectCall(
            lineaTokenBridge,
            0, // No ETH value
            abi.encodeWithSelector(
                BRIDGE_TOKEN_SELECTOR,
                address(fixture.dai), // token
                TOKENS_TO_SEND, // amount
                address(mockSpoke) // recipient
            )
        );

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
    }

    /**
     * @notice Test: Correctly calls the CCTP bridge adapter when attempting to bridge USDC
     * @dev Verifies that executing a root bundle properly bridges USDC via CCTP V2.
     */
    function test_relayTokens_BridgesUsdcViaCCTP() public {
        // Add liquidity for USDC
        addLiquidity(fixture.usdc, USDC_TO_SEND);

        // Build merkle tree with single USDC leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            LINEA_CHAIN_ID,
            address(fixture.usdc),
            USDC_TO_SEND,
            USDC_LP_FEES
        );

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

        // Verify HubPool approved the CCTP TokenMessenger to spend USDC
        assertEq(
            fixture.usdc.allowance(address(fixture.hubPool), address(cctpMessenger)),
            USDC_TO_SEND,
            "Allowance should be set for CCTP TokenMessenger"
        );

        // Verify depositForBurn was called once
        assertEq(cctpMessenger.depositForBurnCallCount(), 1, "depositForBurn should be called once");

        // Verify depositForBurn parameters (V2 signature)
        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold
        ) = cctpMessenger.lastDepositForBurnCall();

        assertEq(amount, USDC_TO_SEND, "Amount should match");
        assertEq(destinationDomain, CircleDomainIds.Linea, "Destination domain should be Linea (11)");
        assertEq(mintRecipient, bytes32(uint256(uint160(address(mockSpoke)))), "Mint recipient should be mockSpoke");
        assertEq(burnToken, address(fixture.usdc), "Burn token should be USDC");
        assertEq(destinationCaller, bytes32(0), "Destination caller should be bytes32(0)");
        assertEq(maxFee, 0, "Max fee should be 0 for standard transfer");
        assertEq(minFinalityThreshold, 2000, "Min finality threshold should be 2000");
    }

    /**
     * @notice Test: Splits USDC into parts to stay under per-message limit when attempting to bridge USDC
     * @dev Verifies that the adapter splits large USDC amounts into multiple calls to stay under burn limit.
     */
    function test_relayTokens_SplitsUsdcWhenOverBurnLimit() public {
        // Use amounts that will require splitting
        // tokensSendToL2 = 100e6 (from Hardhat test)
        // Set limit to tokensSendToL2 / 2 - 1 to force 3 calls
        uint256 newLimit = USDC_TO_SEND / 2 - 1; // 49999999 (~49.999999 USDC)
        cctpMinter.setBurnLimit(newLimit);

        // Add liquidity for USDC
        addLiquidity(fixture.usdc, USDC_TO_SEND);

        // Build merkle tree with single USDC leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            LINEA_CHAIN_ID,
            address(fixture.usdc),
            USDC_TO_SEND,
            USDC_LP_FEES
        );

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

        // With limit = 49999999 and amount = 100000000:
        // Call 1: 49999999
        // Call 2: 49999999
        // Call 3: 2 (remainder)
        assertEq(cctpMessenger.depositForBurnCallCount(), 3, "depositForBurn should be called 3 times");

        // Verify first call
        (
            uint256 amount1,
            uint32 destDomain1,
            bytes32 recipient1,
            address burnToken1,
            bytes32 destCaller1,
            uint256 maxFee1,
            uint32 finality1
        ) = cctpMessenger.getDepositForBurnCall(0);
        assertEq(amount1, newLimit, "First call amount should be burn limit");
        assertEq(destDomain1, CircleDomainIds.Linea, "First call domain should be Linea");
        assertEq(recipient1, bytes32(uint256(uint160(address(mockSpoke)))), "First call recipient should be mockSpoke");
        assertEq(burnToken1, address(fixture.usdc), "First call token should be USDC");
        assertEq(destCaller1, bytes32(0), "First call destination caller should be 0");
        assertEq(maxFee1, 0, "First call max fee should be 0");
        assertEq(finality1, 2000, "First call finality should be 2000");

        // Verify second call
        (uint256 amount2, , , , , , ) = cctpMessenger.getDepositForBurnCall(1);
        assertEq(amount2, newLimit, "Second call amount should be burn limit");

        // Verify third call (remainder)
        (uint256 amount3, , , , , , ) = cctpMessenger.getDepositForBurnCall(2);
        assertEq(amount3, 2, "Third call amount should be remainder (2)");

        // Test case 2: Amount divides evenly into limit
        // Reset call count by redeploying the mock
        cctpMinter = new MockCCTPMinter();
        uint256 evenLimit = USDC_TO_SEND / 2; // 50000000 (50 USDC)
        cctpMinter.setBurnLimit(evenLimit);
        cctpMessenger = new MockCCTPMessengerV2(ITokenMinter(address(cctpMinter)), address(this));

        // Redeploy adapter with new messenger
        adapter = new Linea_Adapter(
            WETH9Interface(address(fixture.weth)),
            IMessageService(lineaMessageService),
            ITokenBridge(lineaTokenBridge),
            fixture.usdc,
            ITokenMessenger(address(cctpMessenger))
        );
        fixture.hubPool.setCrossChainContracts(LINEA_CHAIN_ID, address(adapter), address(mockSpoke));

        // Add more liquidity and propose another bundle
        addLiquidity(fixture.usdc, USDC_TO_SEND);

        (HubPoolInterface.PoolRebalanceLeaf memory leaf2, bytes32 root2) = MerkleTreeUtils.buildSingleTokenLeaf(
            LINEA_CHAIN_ID,
            address(fixture.usdc),
            USDC_TO_SEND,
            USDC_LP_FEES
        );

        proposeBundleAndAdvanceTime(root2, MOCK_RELAYER_REFUND_ROOT, MOCK_SLOW_RELAY_ROOT);

        fixture.hubPool.executeRootBundle(
            leaf2.chainId,
            leaf2.groupIndex,
            leaf2.bundleLpFees,
            leaf2.netSendAmounts,
            leaf2.runningBalances,
            leaf2.leafId,
            leaf2.l1Tokens,
            MerkleTreeUtils.emptyProof()
        );

        // With limit = 50000000 and amount = 100000000:
        // Call 1: 50000000
        // Call 2: 50000000
        assertEq(cctpMessenger.depositForBurnCallCount(), 2, "depositForBurn should be called 2 times for even split");

        (uint256 evenAmount1, , , , , , ) = cctpMessenger.getDepositForBurnCall(0);
        (uint256 evenAmount2, , , , , , ) = cctpMessenger.getDepositForBurnCall(1);
        assertEq(evenAmount1, evenLimit, "First even call amount should be burn limit");
        assertEq(evenAmount2, evenLimit, "Second even call amount should be burn limit");
    }

    /**
     * @notice Test: Correctly unwraps WETH and bridges ETH
     * @dev Verifies that when bridging WETH, the adapter unwraps it and sends ETH via MessageService.
     */
    function test_relayTokens_UnwrapsWETHAndBridgesETH() public {
        // Add liquidity for WETH using helper (handles bond requirement)
        addWethLiquidityWithBond(TOKENS_TO_SEND);

        // Build merkle tree with single WETH leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            LINEA_CHAIN_ID,
            address(fixture.weth),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // For WETH, the adapter unwraps to ETH and sends via MessageService
        // sendMessage(to, 0, "") with msg.value = amount
        vm.expectCall(
            lineaMessageService,
            TOKENS_TO_SEND, // ETH value
            abi.encodeWithSelector(
                SEND_MESSAGE_SELECTOR,
                address(mockSpoke), // target
                uint256(0), // fee (set to 0)
                "" // empty calldata for ETH transfer
            )
        );

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
    }
}
