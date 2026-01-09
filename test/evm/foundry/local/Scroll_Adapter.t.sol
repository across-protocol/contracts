// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Scroll_Adapter } from "../../../../contracts/chain-adapters/Scroll_Adapter.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

// Mocks - only need MockSpokePool for the target
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Scroll interfaces
import { IL1GatewayRouter } from "@scroll-tech/contracts/L1/gateways/IL1GatewayRouter.sol";
import { IL1ScrollMessenger } from "@scroll-tech/contracts/L1/IL1ScrollMessenger.sol";
import { IL2GasPriceOracle } from "@scroll-tech/contracts/L1/rollup/IL2GasPriceOracle.sol";

// Function selectors (defined as constants since interfaces may not expose them)
bytes4 constant SEND_MESSAGE_SELECTOR = bytes4(keccak256("sendMessage(address,uint256,bytes,uint256)"));
bytes4 constant ESTIMATE_FEE_SELECTOR = bytes4(keccak256("estimateCrossDomainMessageFee(uint256)"));
bytes4 constant DEPOSIT_ERC20_SELECTOR = bytes4(keccak256("depositERC20(address,address,uint256,uint256)"));
bytes4 constant GET_L2_ADDRESS_SELECTOR = bytes4(keccak256("getL2ERC20Address(address)"));

/**
 * @title Scroll_AdapterTest
 * @notice Foundry tests for Scroll_Adapter using vm.mockCall/vm.expectCall cheatcodes.
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
    MockSpokePool mockSpoke;

    // Fake addresses for mocked contracts (no actual code deployed)
    address l1Messenger;
    address l1GasPriceOracle;
    address l1GatewayRouter;

    // ============ Chain Constants ============

    uint256 constant SCROLL_CHAIN_ID = 534351;
    uint32 constant L2_MESSAGE_GAS_LIMIT = 2_000_000;
    uint32 constant L2_TOKEN_GAS_LIMIT = 250_000;

    // ============ Test Amounts ============

    uint256 constant TOKENS_TO_SEND = 100 ether;
    uint256 constant LP_FEES = 10 ether;
    uint256 constant MOCKED_RELAYER_FEE = 10_000;

    // ============ Mock Roots ============

    bytes32 constant MOCK_TREE_ROOT = keccak256("mockTreeRoot");

    // ============ Setup ============

    function setUp() public {
        createHubPoolFixture();

        // Deploy MockSpokePool (still needed as a real target)
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(fixture.weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, address(this), address(fixture.hubPool)))
        );
        mockSpoke = MockSpokePool(payable(proxy));

        // Create fake addresses for the Scroll bridge contracts
        l1Messenger = makeAddr("l1Messenger");
        l1GasPriceOracle = makeAddr("l1GasPriceOracle");
        l1GatewayRouter = makeAddr("l1GatewayRouter");

        // IMPORTANT: Use vm.etch to put dummy code at these addresses
        // Otherwise Solidity's extcodesize check will cause calls to revert
        vm.etch(l1Messenger, hex"00");
        vm.etch(l1GasPriceOracle, hex"00");
        vm.etch(l1GatewayRouter, hex"00");

        // Deploy Scroll_Adapter with fake addresses
        adapter = new Scroll_Adapter(
            IL1GatewayRouter(l1GatewayRouter),
            IL1ScrollMessenger(l1Messenger),
            IL2GasPriceOracle(l1GasPriceOracle),
            L2_MESSAGE_GAS_LIMIT,
            L2_TOKEN_GAS_LIMIT
        );

        // Configure HubPool
        fixture.hubPool.setCrossChainContracts(SCROLL_CHAIN_ID, address(adapter), address(mockSpoke));
        fixture.hubPool.setPoolRebalanceRoute(SCROLL_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        fixture.hubPool.setPoolRebalanceRoute(SCROLL_CHAIN_ID, address(fixture.dai), fixture.l2Dai);
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage fails when there's not enough fees
     */
    function test_relayMessage_RevertsWhenInsufficientFees() public {
        // Mock the gas price oracle to return an excessive fee
        uint256 excessiveFee = LP_ETH_FUNDING + 1;
        vm.mockCall(l1GasPriceOracle, abi.encodeWithSelector(ESTIMATE_FEE_SELECTOR), abi.encode(excessiveFee));

        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        vm.expectRevert();
        fixture.hubPool.relaySpokePoolAdminFunction(SCROLL_CHAIN_ID, functionCallData);
    }

    /**
     * @notice Test: relayMessage calls spoke pool functions
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        // Mock the gas price oracle return value
        vm.mockCall(l1GasPriceOracle, abi.encodeWithSelector(ESTIMATE_FEE_SELECTOR), abi.encode(MOCKED_RELAYER_FEE));

        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Expect the sendMessage call with specific parameters
        // vm.expectCall verifies the call is made (reverts test if not)
        vm.expectCall(
            l1Messenger,
            MOCKED_RELAYER_FEE, // Expected msg.value
            abi.encodeWithSelector(
                SEND_MESSAGE_SELECTOR,
                address(mockSpoke), // target
                uint256(0), // value (no ETH to target)
                functionCallData, // message
                uint256(L2_MESSAGE_GAS_LIMIT) // gasLimit
            )
        );

        // Mock the sendMessage to succeed (return nothing)
        vm.mockCall(l1Messenger, abi.encodeWithSelector(SEND_MESSAGE_SELECTOR), abi.encode());

        fixture.hubPool.relaySpokePoolAdminFunction(SCROLL_CHAIN_ID, functionCallData);
    }

    /**
     * @notice Test: Correctly calls appropriate scroll bridge functions when transferring tokens
     */
    function test_relayTokens_BridgesTokensViaGatewayRouter() public {
        // Mock the gas price oracle
        vm.mockCall(l1GasPriceOracle, abi.encodeWithSelector(ESTIMATE_FEE_SELECTOR), abi.encode(MOCKED_RELAYER_FEE));

        // Mock getL2ERC20Address to return the L2 DAI address
        vm.mockCall(
            l1GatewayRouter,
            abi.encodeWithSelector(GET_L2_ADDRESS_SELECTOR, address(fixture.dai)),
            abi.encode(fixture.l2Dai)
        );

        // Mock depositERC20 to succeed
        vm.mockCall(l1GatewayRouter, abi.encodeWithSelector(DEPOSIT_ERC20_SELECTOR), abi.encode());

        // Mock sendMessage to succeed (for relayRootBundle)
        vm.mockCall(l1Messenger, abi.encodeWithSelector(SEND_MESSAGE_SELECTOR), abi.encode());

        // Add liquidity
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            SCROLL_CHAIN_ID,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        proposeBundleAndAdvanceTime(root, MOCK_TREE_ROOT, MOCK_TREE_ROOT);

        // Expect depositERC20 call with correct parameters
        vm.expectCall(
            l1GatewayRouter,
            MOCKED_RELAYER_FEE, // Expected msg.value
            abi.encodeWithSelector(
                DEPOSIT_ERC20_SELECTOR,
                address(fixture.dai), // token
                address(mockSpoke), // to
                TOKENS_TO_SEND, // amount
                uint256(L2_TOKEN_GAS_LIMIT) // gasLimit
            )
        );

        // Expect sendMessage call for relayRootBundle
        vm.expectCall(l1Messenger, MOCKED_RELAYER_FEE, abi.encodeWithSelector(SEND_MESSAGE_SELECTOR));

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
