// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Solana_Adapter } from "../../../../contracts/chain-adapters/Solana_Adapter.sol";
import { AdapterInterface } from "../../../../contracts/chain-adapters/interfaces/AdapterInterface.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { CircleDomainIds } from "../../../../contracts/libraries/CircleCCTPAdapter.sol";
import { Bytes32ToAddress } from "../../../../contracts/libraries/AddressConverters.sol";

// CCTP mocks
import { MockCCTPMinter, MockCCTPMessenger, MockCCTPMessageTransmitter } from "../../../../contracts/test/MockCCTP.sol";
import { ITokenMessenger, IMessageTransmitter } from "../../../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title Solana_AdapterTest
 * @notice Foundry tests for Solana_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/Solana_Adapter.ts
 * Tests migrated:
 *   1. relayMessage calls spoke pool functions
 *   2. Correctly calls the CCTP bridge adapter when attempting to bridge USDC
 */
contract Solana_AdapterTest is HubPoolTestBase {
    using Bytes32ToAddress for bytes32;

    // ============ Contracts ============

    Solana_Adapter adapter;
    MockCCTPMinter cctpMinter;
    MockCCTPMessenger cctpMessenger;
    MockCCTPMessageTransmitter cctpMessageTransmitter;

    // ============ Solana Address Constants ============

    // Random bytes32 addresses representing Solana addresses (base58-decoded)
    bytes32 solanaSpokePoolBytes32;
    bytes32 solanaUsdcBytes32;
    bytes32 solanaSpokePoolUsdcVaultBytes32;

    // EVM address representations of Solana addresses (lowest 20 bytes)
    address solanaSpokePoolAddress;
    address solanaUsdcAddress;

    // ============ Chain Constants ============

    // Placeholder chain ID for Solana (not an EVM chain, so no official chain ID)
    uint256 constant SOLANA_CHAIN_ID = 1234567890;

    // ============ Test Amounts ============

    uint256 constant TOKENS_TO_SEND = 100e6; // USDC has 6 decimals
    uint256 constant LP_FEES = 10e6;
    uint256 constant BURN_LIMIT = 1_000_000e6; // 1M USDC per message

    // ============ Setup ============

    function setUp() public {
        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Generate random Solana addresses as bytes32
        solanaSpokePoolBytes32 = keccak256("solanaSpokePool");
        solanaUsdcBytes32 = keccak256("solanaUsdc");
        solanaSpokePoolUsdcVaultBytes32 = keccak256("solanaSpokePoolUsdcVault");

        // Convert to EVM address representation (lowest 20 bytes)
        solanaSpokePoolAddress = solanaSpokePoolBytes32.toAddressUnchecked();
        solanaUsdcAddress = solanaUsdcBytes32.toAddressUnchecked();

        // Deploy CCTP mocks
        cctpMinter = new MockCCTPMinter();
        cctpMinter.setBurnLimit(BURN_LIMIT);
        cctpMessenger = new MockCCTPMessenger(cctpMinter);
        cctpMessageTransmitter = new MockCCTPMessageTransmitter();

        // Deploy Solana_Adapter
        adapter = new Solana_Adapter(
            fixture.usdc,
            ITokenMessenger(address(cctpMessenger)),
            IMessageTransmitter(address(cctpMessageTransmitter)),
            solanaSpokePoolBytes32,
            solanaUsdcBytes32,
            solanaSpokePoolUsdcVaultBytes32
        );

        // Configure HubPool with adapter
        fixture.hubPool.setCrossChainContracts(SOLANA_CHAIN_ID, address(adapter), solanaSpokePoolAddress);
        fixture.hubPool.setPoolRebalanceRoute(SOLANA_CHAIN_ID, address(fixture.usdc), solanaUsdcAddress);

        // Enable USDC for LP
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.usdc));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage calls spoke pool functions
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction properly calls through
     *      Solana_Adapter to send a message via CCTP MessageTransmitter.
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        // Encode a mock setCrossDomainAdmin function call
        address newAdmin = makeAddr("newAdmin");
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", newAdmin);

        // Events are emitted in this order:
        // 1. SendMessageCalled (from MockCCTPMessageTransmitter)
        // 2. MessageRelayed (from adapter via delegatecall in HubPool context)

        // Expect SendMessageCalled event from MockCCTPMessageTransmitter (emitted first)
        vm.expectEmit(true, true, true, true, address(cctpMessageTransmitter));
        emit MockCCTPMessageTransmitter.SendMessageCalled(
            CircleDomainIds.Solana,
            solanaSpokePoolBytes32,
            functionCallData
        );

        // Expect MessageRelayed event from the adapter (emitted via delegatecall context on HubPool)
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit AdapterInterface.MessageRelayed(solanaSpokePoolAddress, functionCallData);

        // Execute relay
        fixture.hubPool.relaySpokePoolAdminFunction(SOLANA_CHAIN_ID, functionCallData);

        // Verify sendMessage was called
        assertEq(cctpMessageTransmitter.sendMessageCallCount(), 1, "sendMessage should be called once");
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly calls the CCTP bridge adapter when attempting to bridge USDC
     * @dev Verifies that executing a root bundle properly bridges USDC to Solana via CCTP.
     */
    function test_relayTokens_BridgesUsdcViaCCTP() public {
        // Add liquidity for USDC
        addLiquidity(fixture.usdc, TOKENS_TO_SEND);

        // Build merkle tree with single USDC leaf
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            SOLANA_CHAIN_ID,
            address(fixture.usdc),
            TOKENS_TO_SEND,
            LP_FEES
        );

        // Propose root bundle and advance past liveness
        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

        // Events are emitted in this order during relayTokens:
        // 1. DepositForBurnCalled (from MockCCTPMessenger)
        // 2. TokensRelayed (from adapter via delegatecall in HubPool context)

        // Expect DepositForBurnCalled event from MockCCTPMessenger (emitted first)
        vm.expectEmit(true, true, true, true, address(cctpMessenger));
        emit MockCCTPMessenger.DepositForBurnCalled(
            TOKENS_TO_SEND,
            CircleDomainIds.Solana,
            solanaSpokePoolUsdcVaultBytes32,
            address(fixture.usdc)
        );

        // Expect TokensRelayed event (emitted via delegatecall context on HubPool)
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit AdapterInterface.TokensRelayed(
            address(fixture.usdc),
            solanaUsdcAddress,
            TOKENS_TO_SEND,
            solanaSpokePoolAddress
        );

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

        // Verify HubPool approved the CCTP TokenMessenger to spend USDC
        // Note: The mock doesn't actually pull tokens, so the allowance remains
        assertEq(
            fixture.usdc.allowance(address(fixture.hubPool), address(cctpMessenger)),
            TOKENS_TO_SEND,
            "Allowance should be set for CCTP TokenMessenger"
        );
    }
}
