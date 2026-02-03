// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../../utils/MerkleTreeUtils.sol";

// Contract under test
import { PolygonZkEVM_Adapter } from "../../../../../contracts/chain-adapters/PolygonZkEVM_Adapter.sol";
import { HubPoolInterface } from "../../../../../contracts/interfaces/HubPoolInterface.sol";
import { WETH9Interface } from "../../../../../contracts/external/interfaces/WETH9Interface.sol";
import { IPolygonZkEVMBridge } from "../../../../../contracts/external/interfaces/IPolygonZkEVMBridge.sol";

// Mocks - only need MockSpokePool for the target
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";

// Function selectors
bytes4 constant BRIDGE_MESSAGE_SELECTOR = bytes4(keccak256("bridgeMessage(uint32,address,bool,bytes)"));
bytes4 constant BRIDGE_ASSET_SELECTOR = bytes4(keccak256("bridgeAsset(uint32,address,uint256,address,bool,bytes)"));

/**
 * @title PolygonZkEVM_AdapterTest
 * @notice Foundry tests for PolygonZkEVM_Adapter using vm.mockCall/vm.expectCall cheatcodes.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/PolygonZkEVM_Adapter.ts
 * Tests migrated:
 *   1. relayMessage calls spoke pool functions
 *   2. Correctly calls appropriate bridge functions when making WETH cross chain calls
 *   3. Correctly calls appropriate bridge functions when making ERC20 cross chain calls
 */
contract PolygonZkEVM_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    PolygonZkEVM_Adapter adapter;
    MockSpokePool mockSpoke;

    // Fake address for mocked bridge contract
    address polygonZkEvmBridge;

    // ============ Chain Constants ============

    uint256 constant POLYGON_ZKEVM_CHAIN_ID = 1101;
    uint32 constant POLYGON_ZKEVM_L2_NETWORK_ID = 1;

    // ============ Setup ============

    function setUp() public {
        createHubPoolFixture();

        // Deploy MockSpokePool using helper
        mockSpoke = deployMockSpokePool(address(this));

        // Create fake address for the bridge contract using helper
        polygonZkEvmBridge = makeFakeContract("polygonZkEvmBridge");

        // Deploy PolygonZkEVM_Adapter with fake bridge address
        adapter = new PolygonZkEVM_Adapter(
            WETH9Interface(address(fixture.weth)),
            IPolygonZkEVMBridge(polygonZkEvmBridge)
        );

        // Configure HubPool
        fixture.hubPool.setCrossChainContracts(POLYGON_ZKEVM_CHAIN_ID, address(adapter), address(mockSpoke));
        fixture.hubPool.setPoolRebalanceRoute(POLYGON_ZKEVM_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        fixture.hubPool.setPoolRebalanceRoute(POLYGON_ZKEVM_CHAIN_ID, address(fixture.dai), fixture.l2Dai);
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage calls spoke pool functions
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Mock bridgeMessage to succeed
        vm.mockCall(polygonZkEvmBridge, abi.encodeWithSelector(BRIDGE_MESSAGE_SELECTOR), abi.encode());

        // Expect the bridgeMessage call with specific parameters
        vm.expectCall(
            polygonZkEvmBridge,
            0, // msg.value = 0
            abi.encodeWithSelector(
                BRIDGE_MESSAGE_SELECTOR,
                POLYGON_ZKEVM_L2_NETWORK_ID, // destinationNetwork
                address(mockSpoke), // destinationAddress
                true, // forceUpdateGlobalExitRoot
                functionCallData // metadata
            )
        );

        fixture.hubPool.relaySpokePoolAdminFunction(POLYGON_ZKEVM_CHAIN_ID, functionCallData);
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly calls appropriate bridge functions when making WETH cross chain calls
     * @dev WETH is unwrapped to ETH and bridged with token=address(0) and msg.value
     */
    function test_relayTokens_BridgesWethAsEth() public {
        // Mock bridgeAsset to succeed
        vm.mockCall(polygonZkEvmBridge, abi.encodeWithSelector(BRIDGE_ASSET_SELECTOR), abi.encode());

        // Mock bridgeMessage for the relayRootBundle call
        vm.mockCall(polygonZkEvmBridge, abi.encodeWithSelector(BRIDGE_MESSAGE_SELECTOR), abi.encode());

        // Add WETH liquidity
        // Note: fixture already approves max WETH to hubPool, don't override with smaller amount
        vm.deal(address(this), TOKENS_TO_SEND);
        fixture.weth.deposit{ value: TOKENS_TO_SEND }();
        fixture.hubPool.addLiquidity(address(fixture.weth), TOKENS_TO_SEND);

        // Build merkle tree for WETH
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            POLYGON_ZKEVM_CHAIN_ID,
            address(fixture.weth),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // Expect bridgeAsset call with ETH (token=address(0), value=amount)
        vm.expectCall(
            polygonZkEvmBridge,
            TOKENS_TO_SEND, // msg.value = amount (ETH bridged)
            abi.encodeWithSelector(
                BRIDGE_ASSET_SELECTOR,
                POLYGON_ZKEVM_L2_NETWORK_ID, // destinationNetwork
                address(mockSpoke), // destinationAddress
                TOKENS_TO_SEND, // amount
                address(0), // token = 0 for ETH
                true, // forceUpdateGlobalExitRoot
                "" // permitData
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
     * @notice Test: Correctly calls appropriate bridge functions when making ERC20 cross chain calls
     */
    function test_relayTokens_BridgesErc20() public {
        // Mock bridgeAsset to succeed
        vm.mockCall(polygonZkEvmBridge, abi.encodeWithSelector(BRIDGE_ASSET_SELECTOR), abi.encode());

        // Mock bridgeMessage for the relayRootBundle call
        vm.mockCall(polygonZkEvmBridge, abi.encodeWithSelector(BRIDGE_MESSAGE_SELECTOR), abi.encode());

        // Add DAI liquidity
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree for DAI
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            POLYGON_ZKEVM_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // Expect bridgeAsset call with DAI (token=dai, no msg.value)
        vm.expectCall(
            polygonZkEvmBridge,
            0, // msg.value = 0
            abi.encodeWithSelector(
                BRIDGE_ASSET_SELECTOR,
                POLYGON_ZKEVM_L2_NETWORK_ID, // destinationNetwork
                address(mockSpoke), // destinationAddress
                TOKENS_TO_SEND, // amount
                address(fixture.dai), // token
                true, // forceUpdateGlobalExitRoot
                "" // permitData
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
