// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { HubPoolTestBase } from "../utils/HubPoolTestBase.sol";
import { MerkleTreeUtils } from "../utils/MerkleTreeUtils.sol";

import { Mock_Adapter, Mock_Bridge } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";
import { HubPool } from "../../../../contracts/HubPool.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @title HubPool_ExecuteRootBundleTest
 * @notice Foundry tests for HubPool.executeRootBundle, ported from Hardhat tests.
 */
contract HubPool_ExecuteRootBundleTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    Mock_Adapter mockAdapter;
    address mockSpoke;
    address dataWorker;
    address liquidityProvider;

    // ============ Constants ============

    uint256 constant REPAYMENT_CHAIN_ID = 777;
    // REFUND_PROPOSAL_LIVENESS, BOND_AMOUNT, FINAL_FEE inherited from HubPoolTestBase
    uint256 constant AMOUNT_TO_LP = 1000 ether;
    uint256 constant WETH_TO_SEND = 100 ether;
    uint256 constant DAI_TO_SEND = 1000 ether;
    uint256 constant WETH_LP_FEE = 1 ether;
    uint256 constant DAI_LP_FEE = 10 ether;

    bytes32 constant MOCK_RELAYER_REFUND_ROOT = bytes32(uint256(0x1234));
    bytes32 constant MOCK_SLOW_RELAY_ROOT = bytes32(uint256(0x5678));

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        // Also sets liveness and identifier in the HubPool
        createHubPoolFixture();

        // Deploy Mock_Adapter and set up cross-chain contracts
        mockAdapter = new Mock_Adapter();
        mockSpoke = makeAddr("mockSpoke");

        fixture.hubPool.setCrossChainContracts(REPAYMENT_CHAIN_ID, address(mockAdapter), mockSpoke);

        // Enable tokens and set pool rebalance routes
        fixture.hubPool.setPoolRebalanceRoute(REPAYMENT_CHAIN_ID, address(fixture.weth), fixture.l2Weth);
        fixture.hubPool.setPoolRebalanceRoute(REPAYMENT_CHAIN_ID, address(fixture.dai), fixture.l2Dai);

        // Enable WETH for LP (creates LP token)
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        // Enable DAI for LP (creates LP token)
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));

        // Create dataWorker and liquidityProvider accounts
        dataWorker = makeAddr("dataWorker");
        liquidityProvider = makeAddr("liquidityProvider");

        // Seed dataWorker wallet: DAI tokens and WETH (bondAmount + finalFee) * 2
        uint256 dataWorkerAmount = (BOND_AMOUNT + FINAL_FEE) * 2;
        fixture.dai.mint(dataWorker, dataWorkerAmount);
        vm.deal(dataWorker, dataWorkerAmount);
        vm.prank(dataWorker);
        fixture.weth.deposit{ value: dataWorkerAmount }();

        // Seed liquidityProvider wallet: DAI tokens and WETH amountToLp * 10
        uint256 liquidityProviderAmount = AMOUNT_TO_LP * 10;
        fixture.dai.mint(liquidityProvider, liquidityProviderAmount);
        vm.deal(liquidityProvider, liquidityProviderAmount);
        vm.prank(liquidityProvider);
        fixture.weth.deposit{ value: liquidityProviderAmount }();

        // Add liquidity for WETH from liquidityProvider
        vm.prank(liquidityProvider);
        fixture.weth.approve(address(fixture.hubPool), AMOUNT_TO_LP);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.weth), AMOUNT_TO_LP);

        // Add liquidity for DAI from liquidityProvider
        fixture.dai.mint(liquidityProvider, AMOUNT_TO_LP * 10);
        vm.prank(liquidityProvider);
        fixture.dai.approve(address(fixture.hubPool), AMOUNT_TO_LP * 10);
        vm.prank(liquidityProvider);
        fixture.hubPool.addLiquidity(address(fixture.dai), AMOUNT_TO_LP * 10);

        // Approve WETH for dataWorker (for bonding)
        vm.prank(dataWorker);
        fixture.weth.approve(address(fixture.hubPool), BOND_AMOUNT * 10);
    }

    // ============ Helper Functions ============

    /**
     * @notice Constructs a simple 2-leaf merkle tree for testing.
     * @dev Mirrors the constructSimpleTree function from Hardhat tests.
     */
    function constructSimpleTree()
        internal
        view
        returns (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root)
    {
        leaves = new HubPoolInterface.PoolRebalanceLeaf[](2);

        // Leaf 0: Contains WETH and DAI, groupIndex = 0 (will relay root bundle)
        {
            uint256[] memory bundleLpFees = new uint256[](2);
            bundleLpFees[0] = WETH_LP_FEE;
            bundleLpFees[1] = DAI_LP_FEE;

            int256[] memory netSendAmounts = new int256[](2);
            netSendAmounts[0] = int256(WETH_TO_SEND);
            netSendAmounts[1] = int256(DAI_TO_SEND);

            int256[] memory runningBalances = new int256[](2);
            runningBalances[0] = int256(WETH_TO_SEND);
            runningBalances[1] = int256(DAI_TO_SEND);

            address[] memory l1Tokens = new address[](2);
            l1Tokens[0] = address(fixture.weth);
            l1Tokens[1] = address(fixture.dai);

            leaves[0] = HubPoolInterface.PoolRebalanceLeaf({
                chainId: REPAYMENT_CHAIN_ID,
                groupIndex: 0,
                bundleLpFees: bundleLpFees,
                netSendAmounts: netSendAmounts,
                runningBalances: runningBalances,
                leafId: 0,
                l1Tokens: l1Tokens
            });
        }

        // Leaf 1: Empty leaf, groupIndex = 1 (will not relay root bundle)
        {
            leaves[1] = HubPoolInterface.PoolRebalanceLeaf({
                chainId: REPAYMENT_CHAIN_ID,
                groupIndex: 1,
                bundleLpFees: new uint256[](0),
                netSendAmounts: new int256[](0),
                runningBalances: new int256[](0),
                leafId: 1,
                l1Tokens: new address[](0)
            });
        }

        // Build the merkle root from leaves
        root = _buildMerkleRoot(leaves);
    }

    /**
     * @notice Builds a merkle root from pool rebalance leaves.
     * @dev For 2 leaves: root = keccak256(leaf0Hash, leaf1Hash)
     */
    function _buildMerkleRoot(HubPoolInterface.PoolRebalanceLeaf[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 1) {
            return keccak256(abi.encode(leaves[0]));
        } else if (leaves.length == 2) {
            bytes32 leaf0Hash = keccak256(abi.encode(leaves[0]));
            bytes32 leaf1Hash = keccak256(abi.encode(leaves[1]));
            // Sort leaves for consistent ordering
            if (leaf0Hash < leaf1Hash) {
                return keccak256(abi.encodePacked(leaf0Hash, leaf1Hash));
            } else {
                return keccak256(abi.encodePacked(leaf1Hash, leaf0Hash));
            }
        }
        revert("Only 1 or 2 leaves supported in test helper");
    }

    /**
     * @notice Gets the merkle proof for a leaf at a given index.
     */
    function _getMerkleProof(
        HubPoolInterface.PoolRebalanceLeaf[] memory leaves,
        uint256 index
    ) internal pure returns (bytes32[] memory) {
        if (leaves.length == 1) {
            return new bytes32[](0);
        } else if (leaves.length == 2) {
            bytes32[] memory proof = new bytes32[](1);
            uint256 siblingIndex = index == 0 ? 1 : 0;
            proof[0] = keccak256(abi.encode(leaves[siblingIndex]));
            return proof;
        }
        revert("Only 1 or 2 leaves supported in test helper");
    }

    /**
     * @notice Proposes a root bundle with the given leaves.
     */
    function _proposeRootBundle(bytes32 poolRebalanceRoot, uint8 leafCount) internal {
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](leafCount);
        for (uint8 i = 0; i < leafCount; i++) {
            bundleEvaluationBlockNumbers[i] = block.number + i;
        }

        vm.prank(dataWorker);
        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            leafCount,
            poolRebalanceRoot,
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
    }

    /**
     * @notice Executes a leaf from the root bundle.
     */
    function _executeLeaf(HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32[] memory proof) internal {
        vm.prank(dataWorker);
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

    // ============ Tests ============

    function test_ExecuteRootBundle_ProducesRelayCallsAndSendsTokens() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);

        // Advance time past liveness
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // Record balances before execution
        uint256 hubPoolWethBefore = fixture.weth.balanceOf(address(fixture.hubPool));
        uint256 hubPoolDaiBefore = fixture.dai.balanceOf(address(fixture.hubPool));

        // Expect events for token relays
        // Note: Mock_Adapter emits events when relayTokens/relayMessage are called
        vm.expectEmit(address(fixture.hubPool));
        emit HubPool.RootBundleExecuted(
            leaves[0].groupIndex,
            leaves[0].leafId,
            leaves[0].chainId,
            leaves[0].l1Tokens,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            dataWorker
        );

        // Record logs to capture adapter events (since Mock_Adapter is delegatecalled, events emit from HubPool)
        vm.recordLogs();

        // Execute first leaf
        bytes32[] memory proof = _getMerkleProof(leaves, 0);
        _executeLeaf(leaves[0], proof);

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Check RelayMessageCalled events
        // Event signature: RelayMessageCalled(address,bytes,address)
        bytes32 relayMessageEventSig = keccak256("RelayMessageCalled(address,bytes,address)");
        uint256 relayMessageCount = 0;
        address relayMessageTarget;
        bytes memory relayMessageData;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == relayMessageEventSig && logs[i].emitter == address(fixture.hubPool)) {
                relayMessageCount++;
                // Decode event data: (address target, bytes message, address caller)
                (relayMessageTarget, relayMessageData, ) = abi.decode(logs[i].data, (address, bytes, address));
            }
        }
        assertEq(relayMessageCount, 1, "Exactly one RelayMessageCalled event should be emitted");
        assertEq(relayMessageTarget, mockSpoke, "RelayMessage target should be mockSpoke");

        // Expected message is the encoded relayRootBundle call
        bytes memory expectedMessage = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
        assertEq(relayMessageData, expectedMessage, "RelayMessage data should match relayRootBundle call");

        // Check RelayTokensCalled events
        // Event signature: RelayTokensCalled(address,address,uint256,address,address)
        bytes32 relayTokensEventSig = keccak256("RelayTokensCalled(address,address,uint256,address,address)");
        uint256 relayTokensCount = 0;
        address[] memory relayTokensL1Tokens = new address[](2);
        address[] memory relayTokensL2Tokens = new address[](2);
        uint256[] memory relayTokensAmounts = new uint256[](2);
        address[] memory relayTokensTo = new address[](2);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == relayTokensEventSig && logs[i].emitter == address(fixture.hubPool)) {
                // Decode event data: (address l1Token, address l2Token, uint256 amount, address to, address caller)
                (
                    relayTokensL1Tokens[relayTokensCount],
                    relayTokensL2Tokens[relayTokensCount],
                    relayTokensAmounts[relayTokensCount],
                    relayTokensTo[relayTokensCount],

                ) = abi.decode(logs[i].data, (address, address, uint256, address, address));
                relayTokensCount++;
            }
        }
        assertEq(relayTokensCount, 2, "Exactly two RelayTokensCalled events should be emitted");

        // First event should be WETH
        assertEq(relayTokensL1Tokens[0], address(fixture.weth), "First RelayTokens l1Token should be WETH");
        assertEq(relayTokensL2Tokens[0], fixture.l2Weth, "First RelayTokens l2Token should be l2Weth");
        assertEq(relayTokensAmounts[0], WETH_TO_SEND, "First RelayTokens amount should be WETH_TO_SEND");
        assertEq(relayTokensTo[0], mockSpoke, "First RelayTokens to should be mockSpoke");

        // Second event should be DAI
        assertEq(relayTokensL1Tokens[1], address(fixture.dai), "Second RelayTokens l1Token should be DAI");
        assertEq(relayTokensL2Tokens[1], fixture.l2Dai, "Second RelayTokens l2Token should be l2Dai");
        assertEq(relayTokensAmounts[1], DAI_TO_SEND, "Second RelayTokens amount should be DAI_TO_SEND");
        assertEq(relayTokensTo[1], mockSpoke, "Second RelayTokens to should be mockSpoke");

        // Verify tokens were sent to the mock bridge
        Mock_Bridge bridge = mockAdapter.bridge();
        assertEq(fixture.weth.balanceOf(address(bridge)), WETH_TO_SEND, "Bridge should have received WETH");
        assertEq(fixture.dai.balanceOf(address(bridge)), DAI_TO_SEND, "Bridge should have received DAI");

        // Verify HubPool balance decreased (note: bond is still held for unexecuted leaf)
        assertEq(
            fixture.weth.balanceOf(address(fixture.hubPool)),
            hubPoolWethBefore - WETH_TO_SEND,
            "HubPool WETH balance mismatch"
        );
        assertEq(
            fixture.dai.balanceOf(address(fixture.hubPool)),
            hubPoolDaiBefore - DAI_TO_SEND,
            "HubPool DAI balance mismatch"
        );

        // Verify leaf count decremented
        (, , , , , uint8 unclaimedPoolRebalanceLeafCount, uint32 challengePeriodEndTimestamp) = fixture
            .hubPool
            .rootBundleProposal();
        assertEq(unclaimedPoolRebalanceLeafCount, 1, "Unclaimed leaf count should be 1");
    }

    function test_ExecuteRootBundle_TwoLeavesDoNotRelayRootTwice() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // Record logs to capture adapter events (since Mock_Adapter is delegatecalled, events emit from HubPool)
        vm.recordLogs();

        // Execute both leaves with same chain ID
        _executeLeaf(leaves[0], _getMerkleProof(leaves, 0));
        _executeLeaf(leaves[1], _getMerkleProof(leaves, 1));

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Check the mockAdapter was called with the correct arguments for each method. The event counts should be identical
        // to the above test.
        // Check RelayMessageCalled events
        // Event signature: RelayMessageCalled(address,bytes,address)
        bytes32 relayMessageEventSig = keccak256("RelayMessageCalled(address,bytes,address)");
        uint256 relayMessageCount = 0;
        address relayMessageTarget;
        bytes memory relayMessageData;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == relayMessageEventSig && logs[i].emitter == address(fixture.hubPool)) {
                relayMessageCount++;
                // Decode event data: (address target, bytes message, address caller)
                (relayMessageTarget, relayMessageData, ) = abi.decode(logs[i].data, (address, bytes, address));
            }
        }
        assertEq(relayMessageCount, 1, "Exactly one message sent from L1->L2");

        // Verify the event args match
        assertEq(relayMessageTarget, mockSpoke, "RelayMessage target should be mockSpoke");

        // Expected message is the encoded relayRootBundle call
        bytes memory expectedMessage = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            MOCK_RELAYER_REFUND_ROOT,
            MOCK_SLOW_RELAY_ROOT
        );
        assertEq(relayMessageData, expectedMessage, "RelayMessage data should match relayRootBundle call");

        // Verify all leaves were executed
        (, , , , , uint8 unclaimedPoolRebalanceLeafCount, uint32 challengePeriodEndTimestamp) = fixture
            .hubPool
            .rootBundleProposal();
        assertEq(unclaimedPoolRebalanceLeafCount, 0, "All leaves should be executed");
    }

    function test_ExecuteRootBundle_AllLeavesReturnsBond() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // Record balance before
        uint256 bondAmount = fixture.hubPool.bondAmount();
        uint256 wethBefore = fixture.weth.balanceOf(dataWorker);

        // Execute first leaf (bond not returned yet)
        _executeLeaf(leaves[0], _getMerkleProof(leaves, 0));
        assertEq(fixture.weth.balanceOf(dataWorker), wethBefore, "Bond should not be returned after first leaf");

        // Execute second leaf (bond should be returned)
        _executeLeaf(leaves[1], _getMerkleProof(leaves, 1));
        assertEq(
            fixture.weth.balanceOf(dataWorker),
            wethBefore + bondAmount,
            "Bond should be returned after all leaves executed"
        );
    }

    function test_ExecuteRootBundle_RevertsIfSpokePoolNotSet() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);

        // Set spoke pool to zero address
        fixture.hubPool.setCrossChainContracts(REPAYMENT_CHAIN_ID, address(mockAdapter), address(0));

        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        vm.expectRevert("SpokePool not initialized");
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );
    }

    function test_ExecuteRootBundle_RevertsIfAdapterNotSet() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);

        // Set adapter to a random (non-contract) address
        fixture.hubPool.setCrossChainContracts(REPAYMENT_CHAIN_ID, makeAddr("random"), mockSpoke);

        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        vm.expectRevert("Adapter not initialized");
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );
    }

    function test_ExecuteRootBundle_RevertsIfDestinationTokenIsZero() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);

        // Set WETH pool rebalance route to zero address
        fixture.hubPool.setPoolRebalanceRoute(REPAYMENT_CHAIN_ID, address(fixture.weth), address(0));

        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        vm.expectRevert("Route not whitelisted");
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );
    }

    function test_ExecuteRootBundle_RejectsBeforeLiveness() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);

        // Warp to 10 seconds before liveness ends
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS - 10);

        vm.expectRevert("Not passed liveness");
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );

        // Warp past liveness - should work now
        vm.warp(block.timestamp + 11);
        _executeLeaf(leaves[0], _getMerkleProof(leaves, 0));
    }

    function test_ExecuteRootBundle_RejectsInvalidLeaves() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // Create a bad leaf with modified chainId
        HubPoolInterface.PoolRebalanceLeaf memory badLeaf = leaves[0];
        badLeaf.chainId = 13371;

        vm.expectRevert("Bad Proof");
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            badLeaf.chainId,
            badLeaf.groupIndex,
            badLeaf.bundleLpFees,
            badLeaf.netSendAmounts,
            badLeaf.runningBalances,
            badLeaf.leafId,
            badLeaf.l1Tokens,
            _getMerkleProof(leaves, 0)
        );
    }

    function test_ExecuteRootBundle_RejectsDoubleClaims() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // First claim should succeed
        _executeLeaf(leaves[0], _getMerkleProof(leaves, 0));

        // Second claim should fail
        vm.expectRevert("Already claimed");
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );
    }

    function test_ExecuteRootBundle_CannotExecuteWhilePaused() public {
        (HubPoolInterface.PoolRebalanceLeaf[] memory leaves, bytes32 root) = constructSimpleTree();

        _proposeRootBundle(root, 2);
        vm.warp(block.timestamp + REFUND_PROPOSAL_LIVENESS + 1);

        // Pause the HubPool
        fixture.hubPool.setPaused(true);

        vm.expectRevert();
        vm.prank(dataWorker);
        fixture.hubPool.executeRootBundle(
            leaves[0].chainId,
            leaves[0].groupIndex,
            leaves[0].bundleLpFees,
            leaves[0].netSendAmounts,
            leaves[0].runningBalances,
            leaves[0].leafId,
            leaves[0].l1Tokens,
            _getMerkleProof(leaves, 0)
        );

        // Unpause and verify execution works
        fixture.hubPool.setPaused(false);
        _executeLeaf(leaves[0], _getMerkleProof(leaves, 0));
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
