// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Polygon_Adapter } from "../../../../contracts/chain-adapters/Polygon_Adapter.sol";
import { IRootChainManager, IFxStateSender, DepositManager } from "../../../../contracts/chain-adapters/Polygon_Adapter.sol";
import { AdapterInterface } from "../../../../contracts/chain-adapters/interfaces/AdapterInterface.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { CircleDomainIds } from "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { MessengerTypes } from "../../../../contracts/AdapterStore.sol";

// Mocks
import { MockCCTPMinter, MockCCTPMessenger } from "../../../../contracts/test/MockCCTP.sol";
import { MockOFTMessenger } from "../../../../contracts/test/MockOFTMessenger.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { RootChainManagerMock, FxStateSenderMock, DepositManagerMock } from "../../../../contracts/test/PolygonMocks.sol";
import { AdapterStore } from "../../../../contracts/AdapterStore.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { ITokenMessenger, ITokenMinter } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/**
 * @title Polygon_AdapterTest
 * @notice Foundry tests for Polygon_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *      Uses PolygonMocks for RootChainManager, FxStateSender, and DepositManager.
 *      Uses MockCCTP for USDC and MockOFTMessenger for USDT.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/Polygon_Adapter.ts
 * Tests migrated:
 *   1. relayMessage calls spoke pool functions
 *   2. Correctly calls appropriate Polygon bridge functions when making ERC20 cross chain calls
 *   3. Correctly unwraps WETH and bridges ETH
 *   4. Correctly bridges matic
 *   5. Correctly calls the CCTP bridge adapter when attempting to bridge USDC
 *   6. Correctly calls the OFT bridge adapter when attempting to bridge USDT
 */
contract Polygon_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Polygon_Adapter adapter;
    MockCCTPMinter cctpMinter;
    MockCCTPMessenger cctpMessenger;
    MockOFTMessenger oftMessenger;
    AdapterStore adapterStore;
    MockSpokePool mockSpoke;

    // Polygon bridge mocks
    RootChainManagerMock rootChainManager;
    FxStateSenderMock fxStateSender;
    DepositManagerMock depositManager;

    // MATIC token (specific to Polygon)
    MintableERC20 matic;
    address l2WMatic;

    // ============ Chain Constants ============

    uint256 constant POLYGON_CHAIN_ID = 137;

    // ERC20 predicate address (doesn't need actual logic for approval testing)
    address erc20Predicate;

    // ============ OFT Constants ============

    uint32 oftPolygonEid;
    uint256 constant OFT_FEE_CAP = 1 ether;

    // ============ Setup ============

    function setUp() public {
        createHubPoolFixture();

        // Deploy MockSpokePool using helper
        mockSpoke = deployMockSpokePool(address(this));

        // Deploy Polygon bridge mocks
        rootChainManager = new RootChainManagerMock();
        fxStateSender = new FxStateSenderMock();
        depositManager = new DepositManagerMock();
        erc20Predicate = makeAddr("erc20Predicate");

        // Deploy MATIC token
        matic = new MintableERC20("Matic", "MATIC", 18);
        l2WMatic = makeAddr("l2WMatic");

        // Deploy CCTP mocks
        cctpMinter = new MockCCTPMinter();
        cctpMinter.setBurnLimit(BURN_LIMIT);
        cctpMessenger = new MockCCTPMessenger(ITokenMinter(address(cctpMinter)));

        // Deploy OFT messenger and adapter store
        oftMessenger = new MockOFTMessenger(address(fixture.usdt));
        adapterStore = new AdapterStore();

        // Get OFT EID for Polygon
        oftPolygonEid = uint32(getOftEid(POLYGON_CHAIN_ID));

        // Configure AdapterStore: USDT -> OFT messenger
        adapterStore.setMessenger(
            MessengerTypes.OFT_MESSENGER,
            oftPolygonEid,
            address(fixture.usdt),
            address(oftMessenger)
        );

        // Deploy Polygon_Adapter
        adapter = new Polygon_Adapter(
            IRootChainManager(address(rootChainManager)),
            IFxStateSender(address(fxStateSender)),
            DepositManager(address(depositManager)),
            erc20Predicate,
            address(matic),
            WETH9Interface(address(fixture.weth)),
            IERC20(address(fixture.usdc)),
            ITokenMessenger(address(cctpMessenger)),
            address(adapterStore),
            oftPolygonEid,
            OFT_FEE_CAP
        );

        // Configure HubPool
        fixture.hubPool.setCrossChainContracts(POLYGON_CHAIN_ID, address(adapter), address(mockSpoke));

        // Set pool rebalance routes and enable tokens for LP
        setupTokenRoutesWithUsdt(POLYGON_CHAIN_ID, fixture.l2Weth, fixture.l2Dai, fixture.l2Usdc, fixture.l2Usdt);

        // Set up MATIC route (Polygon-specific)
        fixture.hubPool.setPoolRebalanceRoute(POLYGON_CHAIN_ID, address(matic), l2WMatic);
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(matic));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage calls spoke pool functions
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction properly calls through
     *      Polygon_Adapter to send a message via FxStateSender.
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Expect MessageRelayed event from adapter (emitted by HubPool since it's a delegatecall)
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit AdapterInterface.MessageRelayed(address(mockSpoke), functionCallData);

        fixture.hubPool.relaySpokePoolAdminFunction(POLYGON_CHAIN_ID, functionCallData);

        // Verify fxStateSender.sendMessageToChild was called with correct params
        assertEq(fxStateSender.sendMessageToChildCallCount(), 1, "sendMessageToChild should be called once");
        (address receiver, bytes memory data) = fxStateSender.lastSendMessageToChildCall();
        assertEq(receiver, address(mockSpoke), "Receiver should be mockSpoke");
        assertEq(data, functionCallData, "Data should match functionCallData");
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly calls appropriate Polygon bridge functions when making ERC20 cross chain calls
     * @dev Verifies that executing a root bundle properly bridges DAI via the RootChainManager.
     */
    function test_relayTokens_BridgesERC20ViaRootChainManager() public {
        // Add liquidity for DAI
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree with single DAI leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            POLYGON_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_SLOW_RELAY_ROOT);

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

        // Verify rootChainManager.depositFor was called once
        assertEq(rootChainManager.depositForCallCount(), 1, "depositFor should be called once");

        // Verify rootChainManager.depositEtherFor was NOT called
        assertEq(rootChainManager.depositEtherForCallCount(), 0, "depositEtherFor should NOT be called");

        // Verify depositFor parameters
        (address user, address rootToken, bytes memory depositData) = rootChainManager.lastDepositForCall();
        assertEq(user, address(mockSpoke), "User should be mockSpoke");
        assertEq(rootToken, address(fixture.dai), "Root token should be DAI");
        assertEq(depositData, abi.encode(TOKENS_TO_SEND), "Deposit data should encode TOKENS_TO_SEND");

        // Verify fxStateSender.sendMessageToChild was called with relayRootBundle data
        assertEq(fxStateSender.sendMessageToChildCallCount(), 1, "sendMessageToChild should be called once");
        (address receiver, bytes memory data) = fxStateSender.lastSendMessageToChildCall();
        assertEq(receiver, address(mockSpoke), "Receiver should be mockSpoke");
        bytes memory expectedRelayRootBundleData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_TREE_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
        assertEq(data, expectedRelayRootBundleData, "Data should be relayRootBundle call");
    }

    /**
     * @notice Test: Correctly unwraps WETH and bridges ETH
     * @dev Verifies that when bridging WETH, the adapter unwraps it and sends ETH via
     *      RootChainManager.depositEtherFor.
     */
    function test_relayTokens_UnwrapsWETHAndBridgesETH() public {
        // Add liquidity for WETH using helper (handles bond requirement)
        addWethLiquidityWithBond(TOKENS_TO_SEND);

        // Build merkle tree with single WETH leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            POLYGON_CHAIN_ID,
            address(fixture.weth),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_SLOW_RELAY_ROOT);

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

        // Verify rootChainManager.depositEtherFor was called once
        assertEq(rootChainManager.depositEtherForCallCount(), 1, "depositEtherFor should be called once");

        // Verify rootChainManager.depositFor was NOT called
        assertEq(rootChainManager.depositForCallCount(), 0, "depositFor should NOT be called");

        // Verify depositEtherFor parameters
        (address user, uint256 value) = rootChainManager.lastDepositEtherForCall();
        assertEq(user, address(mockSpoke), "User should be mockSpoke");
        assertEq(value, TOKENS_TO_SEND, "Value should be TOKENS_TO_SEND");

        // Verify fxStateSender.sendMessageToChild was called with relayRootBundle data
        assertEq(fxStateSender.sendMessageToChildCallCount(), 1, "sendMessageToChild should be called once");
        (address receiver, bytes memory data) = fxStateSender.lastSendMessageToChildCall();
        assertEq(receiver, address(mockSpoke), "Receiver should be mockSpoke");
        bytes memory expectedRelayRootBundleData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_TREE_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
        assertEq(data, expectedRelayRootBundleData, "Data should be relayRootBundle call");
    }

    /**
     * @notice Test: Correctly bridges matic
     * @dev Verifies that MATIC is bridged via the Plasma bridge (DepositManager.depositERC20ForUser).
     */
    function test_relayTokens_BridgesMaticViaPlasma() public {
        // Add liquidity for MATIC
        matic.mint(address(this), TOKENS_TO_SEND);
        matic.approve(address(fixture.hubPool), TOKENS_TO_SEND);
        fixture.hubPool.addLiquidity(address(matic), TOKENS_TO_SEND);

        // Build merkle tree with single MATIC leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            POLYGON_CHAIN_ID,
            address(matic),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_SLOW_RELAY_ROOT);

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

        // Verify depositManager.depositERC20ForUser was called once
        assertEq(depositManager.depositERC20ForUserCallCount(), 1, "depositERC20ForUser should be called once");

        // Verify depositERC20ForUser parameters
        (address token, address user, uint256 amount) = depositManager.lastDepositERC20ForUserCall();
        assertEq(token, address(matic), "Token should be MATIC");
        assertEq(user, address(mockSpoke), "User should be mockSpoke");
        assertEq(amount, TOKENS_TO_SEND, "Amount should be TOKENS_TO_SEND");

        // Verify rootChainManager.depositFor was NOT called (no PoS calls)
        assertEq(rootChainManager.depositForCallCount(), 0, "depositFor should NOT be called");

        // Verify rootChainManager.depositEtherFor was NOT called (no PoS calls)
        assertEq(rootChainManager.depositEtherForCallCount(), 0, "depositEtherFor should NOT be called");

        // Verify fxStateSender.sendMessageToChild was called with relayRootBundle data
        assertEq(fxStateSender.sendMessageToChildCallCount(), 1, "sendMessageToChild should be called once");
        (address receiver, bytes memory data) = fxStateSender.lastSendMessageToChildCall();
        assertEq(receiver, address(mockSpoke), "Receiver should be mockSpoke");
        bytes memory expectedRelayRootBundleData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_TREE_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
        assertEq(data, expectedRelayRootBundleData, "Data should be relayRootBundle call");
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
            POLYGON_CHAIN_ID,
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

        // Verify depositForBurn parameters
        (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) = cctpMessenger
            .lastDepositForBurnCall();

        assertEq(amount, USDC_TO_SEND, "Amount should match");
        assertEq(destinationDomain, CircleDomainIds.Polygon, "Destination domain should be Polygon (7)");
        assertEq(mintRecipient, bytes32(uint256(uint160(address(mockSpoke)))), "Mint recipient should be mockSpoke");
        assertEq(burnToken, address(fixture.usdc), "Burn token should be USDC");
    }

    /**
     * @notice Test: Correctly calls the OFT bridge adapter when attempting to bridge USDT
     * @dev Verifies that executing a root bundle properly bridges USDT via OFT.
     */
    function test_relayTokens_BridgesUsdtViaOFT() public {
        // Ensure HubPool has ETH balance to pay native OFT fee if needed
        vm.deal(address(fixture.hubPool), 1 ether);

        // Add liquidity for USDT
        addLiquidity(fixture.usdt, USDT_TO_SEND);

        // Build merkle tree with single USDT leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            POLYGON_CHAIN_ID,
            address(fixture.usdt),
            USDT_TO_SEND,
            USDT_LP_FEES
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

        // Verify HubPool approved the OFT messenger to spend USDT
        assertEq(
            fixture.usdt.allowance(address(fixture.hubPool), address(oftMessenger)),
            USDT_TO_SEND,
            "Allowance should be set for OFT messenger"
        );

        // Verify send was called once
        assertEq(oftMessenger.sendCallCount(), 1, "send should be called once");

        // Verify send parameters (destructure the tuple from public struct getter)
        (uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, , , ) = oftMessenger.lastSendParam();

        assertEq(dstEid, oftPolygonEid, "Destination EID should match");
        assertEq(to, bytes32(uint256(uint160(address(mockSpoke)))), "Recipient should be mockSpoke");
        assertEq(amountLD, USDT_TO_SEND, "Amount should match");
        assertEq(minAmountLD, USDT_TO_SEND, "Min amount should match");
        assertEq(oftMessenger.lastRefundAddress(), address(fixture.hubPool), "Refund address should be HubPool");
    }
}
