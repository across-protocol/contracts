// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Test utilities
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

// Contract under test
import { Ethereum_Adapter } from "../../../../contracts/chain-adapters/Ethereum_Adapter.sol";
import { AdapterInterface } from "../../../../contracts/chain-adapters/interfaces/AdapterInterface.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

// Existing mocks
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";

/**
 * @title Ethereum_AdapterTest
 * @notice Foundry tests for Ethereum_Adapter, ported from Hardhat tests.
 * @dev Tests relayMessage and relayTokens functionality via HubPool delegatecall.
 *
 * Hardhat source: test/evm/hardhat/chain-adapters/Ethereum_Adapter.ts
 * Tests migrated:
 *   1. relayMessage calls spoke pool functions
 *   2. Correctly transfers tokens when executing pool rebalance
 */
contract Ethereum_AdapterTest is HubPoolTestBase {
    // ============ Contracts ============

    Ethereum_Adapter adapter;
    MockSpokePool mockSpoke;

    // ============ Address Constants ============

    address constant CROSS_DOMAIN_ADMIN = address(0xAD1);
    address constant NEW_ADMIN = address(0xAD2);

    // ============ Chain Constants ============

    uint256 l1ChainId;

    // ============ Setup ============

    function setUp() public {
        // Get the L1 chain ID (simulating mainnet where HubPool and Ethereum_SpokePool coexist)
        l1ChainId = block.chainid;

        // Create HubPool fixture (deploys HubPool, WETH, tokens, UMA mocks)
        createHubPoolFixture();

        // Deploy MockSpokePool using helper
        mockSpoke = deployMockSpokePool(CROSS_DOMAIN_ADMIN);

        // Deploy Ethereum_Adapter
        adapter = new Ethereum_Adapter();

        // Configure HubPool with adapter and mockSpoke
        fixture.hubPool.setCrossChainContracts(l1ChainId, address(adapter), address(mockSpoke));

        // Set pool rebalance routes for L1 tokens (for Ethereum adapter, l2Token == l1Token)
        fixture.hubPool.setPoolRebalanceRoute(l1ChainId, address(fixture.weth), address(fixture.weth));
        fixture.hubPool.setPoolRebalanceRoute(l1ChainId, address(fixture.dai), address(fixture.dai));

        // Enable tokens for LP
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));

        // Transfer ownership of MockSpokePool to HubPool
        // HubPool must own MockSpoke because Ethereum_Adapter.relayMessage calls target directly,
        // and MockSpokePool's _requireAdminSender is onlyOwner
        mockSpoke.transferOwnership(address(fixture.hubPool));
    }

    // ============ relayMessage Tests ============

    /**
     * @notice Test: relayMessage calls spoke pool functions
     * @dev Verifies that HubPool.relaySpokePoolAdminFunction properly calls through
     *      Ethereum_Adapter to execute admin functions on the spoke pool.
     */
    function test_relayMessage_CallsSpokePoolFunctions() public {
        // Verify initial crossDomainAdmin
        assertEq(mockSpoke.crossDomainAdmin(), CROSS_DOMAIN_ADMIN, "Initial admin mismatch");

        // Encode setCrossDomainAdmin function call
        bytes memory functionCallData = abi.encodeWithSignature("setCrossDomainAdmin(address)", NEW_ADMIN);

        // Expect MessageRelayed event from the adapter (emitted via delegatecall context on HubPool)
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit AdapterInterface.MessageRelayed(address(mockSpoke), functionCallData);

        // Execute relay
        fixture.hubPool.relaySpokePoolAdminFunction(l1ChainId, functionCallData);

        // Verify crossDomainAdmin was changed
        assertEq(mockSpoke.crossDomainAdmin(), NEW_ADMIN, "Admin not updated");
    }

    // ============ relayTokens Tests ============

    /**
     * @notice Test: Correctly transfers tokens when executing pool rebalance
     * @dev Verifies that executing a root bundle properly transfers tokens to the spoke pool
     *      via the Ethereum_Adapter's relayTokens function.
     */
    function test_relayTokens_TransfersTokensOnPoolRebalance() public {
        // Add liquidity for DAI
        addLiquidity(fixture.dai, TOKENS_TO_SEND);

        // Build merkle tree with single DAI leaf
        // Note: For Ethereum adapter, l2Token == l1Token since same chain
        (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) = MerkleTreeUtils.buildSingleTokenLeaf(
            l1ChainId,
            address(fixture.dai),
            TOKENS_TO_SEND,
            LP_FEES
        );

        // Propose root bundle and advance past liveness
        proposeBundleAndAdvanceTime(root, bytes32(0), bytes32(0));

        // Record mockSpoke DAI balance before
        uint256 spokeBalanceBefore = fixture.dai.balanceOf(address(mockSpoke));

        // Expect TokensRelayed event (emitted via delegatecall context on HubPool)
        // For Ethereum adapter, l1Token and l2Token are the same
        vm.expectEmit(true, true, true, true, address(fixture.hubPool));
        emit AdapterInterface.TokensRelayed(
            address(fixture.dai),
            address(fixture.dai),
            TOKENS_TO_SEND,
            address(mockSpoke)
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

        // Verify tokens were transferred to mockSpoke
        uint256 spokeBalanceAfter = fixture.dai.balanceOf(address(mockSpoke));
        assertEq(spokeBalanceAfter - spokeBalanceBefore, TOKENS_TO_SEND, "Token transfer amount mismatch");
    }
}
