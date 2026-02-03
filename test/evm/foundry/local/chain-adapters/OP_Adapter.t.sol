// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { ERC20, IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { IOpUSDCBridgeAdapter } from "../../../../../contracts/external/interfaces/IOpUSDCBridgeAdapter.sol";
import { ITokenMessenger } from "../../../../../contracts/external/interfaces/CCTPInterfaces.sol";

import { OP_Adapter } from "../../../../../contracts/chain-adapters/OP_Adapter.sol";
import { CircleDomainIds } from "../../../../../contracts/libraries/CircleCCTPAdapter.sol";
import { WETH9Interface } from "../../../../../contracts/external/interfaces/WETH9Interface.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";

// Test utilities
import { HubPoolTestBase } from "../../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../../utils/MerkleTreeUtils.sol";

// Mocks
import { MockBedrockL1StandardBridge, MockBedrockCrossDomainMessenger } from "../../../../../contracts/test/MockBedrockStandardBridge.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { HubPoolInterface } from "../../../../../contracts/interfaces/HubPoolInterface.sol";

/**
 * @title MockOpUSDCBridge
 * @notice Mock for IOpUSDCBridgeAdapter to track calls.
 */
contract MockOpUSDCBridge is IOpUSDCBridgeAdapter {
    uint256 public sendMessageCallCount;
    address public lastTo;
    uint256 public lastAmount;
    uint32 public lastMinGasLimit;

    function sendMessage(address _to, uint256 _amount, uint32 _minGasLimit) external override {
        sendMessageCallCount++;
        lastTo = _to;
        lastAmount = _amount;
        lastMinGasLimit = _minGasLimit;
    }
}

/**
 * @title OP_AdapterConstructorTest
 * @notice Tests for OP_Adapter constructor validation.
 * @dev These tests verify the InvalidBridgeConfig error conditions.
 */
contract OP_AdapterConstructorTest is Test {
    ERC20 l1Usdc;
    WETH9 l1Weth;

    IL1StandardBridge standardBridge;
    IOpUSDCBridgeAdapter opUSDCBridge;
    ITokenMessenger cctpMessenger;

    uint32 constant RECIPIENT_CIRCLE_DOMAIN_ID = 1;

    function setUp() public {
        l1Usdc = new ERC20("l1Usdc", "l1Usdc");
        l1Weth = new WETH9();

        standardBridge = IL1StandardBridge(makeAddr("standardBridge"));
        opUSDCBridge = IOpUSDCBridgeAdapter(makeAddr("opUSDCBridge"));
        cctpMessenger = ITokenMessenger(makeAddr("cctpMessenger"));
    }

    function testUSDCNotSet() public {
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(0)),
            address(0),
            standardBridge,
            IOpUSDCBridgeAdapter(address(0)),
            ITokenMessenger(address(0)),
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testL1UsdcBridgeSet() public {
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(l1Usdc)),
            address(0),
            standardBridge,
            opUSDCBridge,
            ITokenMessenger(address(0)),
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testCctpMessengerSet() public {
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(0)),
            address(0),
            standardBridge,
            IOpUSDCBridgeAdapter(address(0)),
            cctpMessenger,
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testNeitherSet() public {
        vm.expectRevert(OP_Adapter.InvalidBridgeConfig.selector);
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(l1Usdc)),
            address(0),
            standardBridge,
            IOpUSDCBridgeAdapter(address(0)),
            ITokenMessenger(address(0)),
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }

    function testBothSet() public {
        vm.expectRevert(OP_Adapter.InvalidBridgeConfig.selector);
        new OP_Adapter(
            WETH9Interface(address(l1Weth)),
            IERC20(address(l1Usdc)),
            address(0),
            standardBridge,
            opUSDCBridge,
            cctpMessenger,
            RECIPIENT_CIRCLE_DOMAIN_ID
        );
    }
}

/**
 * @title OP_AdapterTest
 * @notice Foundry tests for OP_Adapter, ported from Hardhat tests.
 * @dev Tests relayTokens functionality via HubPool delegatecall.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/OP_Adapter.ts
 * Tests migrated:
 *   1. Correctly routes USDC via the configured OP USDC bridge
 */
contract OP_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    OP_Adapter adapter;
    MockBedrockL1StandardBridge l1StandardBridge;
    MockBedrockCrossDomainMessenger l1CrossDomainMessenger;
    MockOpUSDCBridge opUSDCBridge;
    MockSpokePool mockSpoke;

    // ============ Chain Constants (loaded from constants.json) ============

    uint256 targetChainId;

    // ============ Setup ============

    function setUp() public {
        // Load chain ID from constants.json
        targetChainId = getChainId("WORLD_CHAIN");

        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Deploy MockSpokePool using helper
        mockSpoke = deployMockSpokePool(address(this));

        // Deploy Optimism bridge mocks
        l1StandardBridge = new MockBedrockL1StandardBridge();
        l1CrossDomainMessenger = new MockBedrockCrossDomainMessenger();

        // Deploy OP USDC bridge mock
        opUSDCBridge = new MockOpUSDCBridge();

        // Deploy OP_Adapter with opUSDCBridge (not CCTP)
        // Use CircleDomainIds.UNINITIALIZED since we're using OP USDC bridge, not CCTP
        adapter = new OP_Adapter(
            WETH9Interface(address(fixture.weth)),
            IERC20(address(fixture.usdc)),
            address(l1CrossDomainMessenger),
            IL1StandardBridge(address(l1StandardBridge)),
            opUSDCBridge,
            ITokenMessenger(address(0)), // No CCTP
            CircleDomainIds.UNINITIALIZED
        );

        // Configure HubPool with adapter and mock spoke
        fixture.hubPool.setCrossChainContracts(targetChainId, address(adapter), address(mockSpoke));

        // Set pool rebalance routes and enable tokens for LP
        setupTokenRoutes(targetChainId, fixture.l2Weth, fixture.l2Dai, fixture.l2Usdc);
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly routes USDC via the configured OP USDC bridge
     * @dev Verifies that executing a root bundle properly bridges USDC via the opUSDCBridge.sendMessage
     *      when CCTP is not configured.
     */
    function test_relayTokens_BridgesUsdcViaOpUSDCBridge() public {
        // Add liquidity for USDC
        addLiquidity(fixture.usdc, USDC_TO_SEND);

        // Build merkle tree with single USDC leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            targetChainId,
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

        // Verify opUSDCBridge.sendMessage was called once
        assertEq(opUSDCBridge.sendMessageCallCount(), 1, "sendMessage should be called once");

        // Verify call parameters using adapter's L2_GAS_LIMIT constant
        assertEq(opUSDCBridge.lastTo(), address(mockSpoke), "Recipient should be mockSpoke");
        assertEq(opUSDCBridge.lastAmount(), USDC_TO_SEND, "Amount should match");
        assertEq(opUSDCBridge.lastMinGasLimit(), adapter.L2_GAS_LIMIT(), "L2 gas limit should match adapter constant");

        // Verify HubPool approved the opUSDCBridge to spend USDC
        assertEq(
            fixture.usdc.allowance(address(fixture.hubPool), address(opUSDCBridge)),
            USDC_TO_SEND,
            "Allowance should be set for opUSDCBridge"
        );
    }
}
