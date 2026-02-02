// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test, Vm, stdError } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { ExpandedERC20WithBlacklist } from "../../../../../contracts/test/ExpandedERC20WithBlacklist.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolUtils } from "../../utils/SpokePoolUtils.sol";
import { AddressToBytes32 } from "../../../../../contracts/libraries/AddressConverters.sol";

/**
 * @title SpokePool_ExecuteRootBundleTest
 * @notice Tests for SpokePool executeRelayerRefundLeaf functionality.
 * @dev Migrated from test/evm/hardhat/SpokePool.ExecuteRootBundle.ts
 */
contract SpokePool_ExecuteRootBundleTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool public spokePool;
    ExpandedERC20WithBlacklist public destErc20;
    WETH9 public weth;

    address public dataWorker;
    address public relayer;
    address public rando;

    uint256 public destinationChainId;

    // Mock merkle roots
    bytes32 public mockSlowRelayRoot;

    event ExecutedRelayerRefundRoot(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint256[] refundAmounts,
        uint32 indexed rootBundleId,
        uint32 indexed leafId,
        address l2TokenAddress,
        address[] refundAddresses,
        bool deferredRefunds,
        address caller
    );

    event TokensBridged(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint32 indexed leafId,
        bytes32 indexed l2TokenAddress,
        address caller
    );

    event BridgedToHubPool(uint256 amount, address token);

    function setUp() public {
        dataWorker = makeAddr("dataWorker");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");

        mockSlowRelayRoot = SpokePoolUtils.createRandomBytes32(1);

        // Deploy WETH
        weth = new WETH9();

        // Deploy destination ERC20 with blacklist functionality
        destErc20 = new ExpandedERC20WithBlacklist("L2 USD Coin", "L2 USDC", 18);
        // Add minter role (Roles.Minter = 1) to this test contract
        destErc20.addMember(1, address(this));

        // Deploy SpokePool
        vm.startPrank(dataWorker);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, dataWorker, dataWorker))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SpokePoolUtils.DESTINATION_CHAIN_ID);
        vm.stopPrank();

        destinationChainId = spokePool.chainId();

        // Seed the spoke pool with tokens
        destErc20.mint(address(spokePool), SpokePoolUtils.AMOUNT_HELD_BY_POOL);
    }

    // ============ Helper Functions ============

    function _createLeaf(
        uint256 chainId,
        uint256 amountToReturn,
        address l2Token,
        address[] memory refundAddresses,
        uint256[] memory refundAmounts,
        uint32 leafId
    ) internal pure returns (SpokePoolInterface.RelayerRefundLeaf memory) {
        return
            SpokePoolInterface.RelayerRefundLeaf({
                amountToReturn: amountToReturn,
                chainId: chainId,
                refundAmounts: refundAmounts,
                leafId: leafId,
                l2TokenAddress: l2Token,
                refundAddresses: refundAddresses
            });
    }

    function _hashLeaf(SpokePoolInterface.RelayerRefundLeaf memory leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(leaf));
    }

    function _buildSingleLeafTree(
        SpokePoolInterface.RelayerRefundLeaf memory leaf
    ) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = _hashLeaf(leaf);
        proof = new bytes32[](0);
    }

    function _buildTwoLeafTree(
        SpokePoolInterface.RelayerRefundLeaf memory leaf0,
        SpokePoolInterface.RelayerRefundLeaf memory leaf1
    ) internal pure returns (bytes32 root, bytes32[] memory proof0, bytes32[] memory proof1) {
        bytes32 hash0 = _hashLeaf(leaf0);
        bytes32 hash1 = _hashLeaf(leaf1);

        // Standard merkle tree: parent = hash(min(left, right) || max(left, right))
        if (uint256(hash0) < uint256(hash1)) {
            root = keccak256(abi.encodePacked(hash0, hash1));
        } else {
            root = keccak256(abi.encodePacked(hash1, hash0));
        }

        proof0 = new bytes32[](1);
        proof0[0] = hash1;

        proof1 = new bytes32[](1);
        proof1[0] = hash0;
    }

    // ============ Tests ============

    /**
     * @notice Test that executing a relayer refund leaf correctly sends tokens to recipients.
     */
    function testDistributeRelayerRefunds() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        SpokePoolInterface.RelayerRefundLeaf memory leaf0 = _createLeaf(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        // Create second leaf with empty refunds
        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        SpokePoolInterface.RelayerRefundLeaf memory leaf1 = _createLeaf(
            destinationChainId,
            0,
            address(destErc20),
            emptyAddresses,
            emptyAmounts,
            1
        );

        (bytes32 root, bytes32[] memory proof0, bytes32[] memory proof1) = _buildTwoLeafTree(leaf0, leaf1);

        // Store the tree
        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        // Execute first leaf
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaf0, proof0);

        uint256 totalRefunded = SpokePoolUtils.AMOUNT_TO_RELAY * 2;

        // Verify balances
        assertEq(destErc20.balanceOf(address(spokePool)), SpokePoolUtils.AMOUNT_HELD_BY_POOL - totalRefunded);
        assertEq(destErc20.balanceOf(relayer), SpokePoolUtils.AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);

        // Execute second leaf (no refunds, should not emit TokensBridged since amountToReturn = 0)
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaf1, proof1);
    }

    /**
     * @notice Test that executing a relayer refund leaf emits the correct events.
     */
    function testExecuteRelayerRefundRootEvents() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        SpokePoolInterface.RelayerRefundLeaf memory leaf = _createLeaf(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleLeafTree(leaf);

        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        // Execute leaf and verify event
        vm.prank(dataWorker);
        vm.expectEmit(true, true, true, true);
        emit ExecutedRelayerRefundRoot(
            SpokePoolUtils.AMOUNT_TO_RETURN,
            destinationChainId,
            refundAmounts,
            0,
            0,
            address(destErc20),
            refundAddresses,
            false,
            dataWorker
        );
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    /**
     * @notice Test that invalid leaf/proof combinations are rejected.
     */
    function testInvalidLeafProof() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        SpokePoolInterface.RelayerRefundLeaf memory leaf = _createLeaf(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleLeafTree(leaf);

        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        // Create a bad leaf by changing chain ID
        SpokePoolInterface.RelayerRefundLeaf memory badLeaf = _createLeaf(
            13371, // Wrong chain ID
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        // Should revert with invalid chain ID (chain ID is checked before merkle proof)
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidChainId.selector);
        spokePool.executeRelayerRefundLeaf(0, badLeaf, proof);

        // Wrong root bundle ID should revert with out-of-bounds (root bundle 1 doesn't exist)
        vm.prank(dataWorker);
        vm.expectRevert(stdError.indexOOBError);
        spokePool.executeRelayerRefundLeaf(1, leaf, proof);
    }

    /**
     * @notice Test that leaf with chain ID for another network cannot be executed.
     */
    function testCannotRefundLeafWithWrongChainId() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        // Create leaf for wrong chain ID
        SpokePoolInterface.RelayerRefundLeaf memory leaf = _createLeaf(
            13371, // Wrong chain ID (not matching spoke pool)
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleLeafTree(leaf);

        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        // Valid tree and proof, but chain ID doesn't match
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidChainId.selector);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    /**
     * @notice Test that double claiming a leaf is rejected.
     */
    function testDoubleClaimPrevention() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        SpokePoolInterface.RelayerRefundLeaf memory leaf = _createLeaf(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleLeafTree(leaf);

        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        // First claim should succeed
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // Second claim should fail
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.ClaimedMerkleLeaf.selector);
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);
    }

    /**
     * @notice Test that deferred refunds are correctly logged when blacklisted address is in refund list.
     */
    function testDeferredRefund() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        SpokePoolInterface.RelayerRefundLeaf memory leaf = _createLeaf(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            address(destErc20),
            refundAddresses,
            refundAmounts,
            0
        );

        (bytes32 root, bytes32[] memory proof) = _buildSingleLeafTree(leaf);

        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Execute should still succeed but defer the blacklisted relayer's refund
        vm.prank(dataWorker);
        vm.expectEmit(true, true, true, true);
        emit ExecutedRelayerRefundRoot(
            SpokePoolUtils.AMOUNT_TO_RETURN,
            destinationChainId,
            refundAmounts,
            0,
            0,
            address(destErc20),
            refundAddresses,
            true, // deferredRefunds = true
            dataWorker
        );
        spokePool.executeRelayerRefundLeaf(0, leaf, proof);

        // Only rando should receive their refund
        assertEq(
            destErc20.balanceOf(address(spokePool)),
            SpokePoolUtils.AMOUNT_HELD_BY_POOL - SpokePoolUtils.AMOUNT_TO_RELAY
        );
        assertEq(destErc20.balanceOf(relayer), 0);
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);
    }

    /**
     * @notice Test that refund address/amount length mismatch reverts.
     */
    function testRefundAddressLengthMismatch() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](3); // Mismatch!
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[2] = 0;

        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidMerkleLeaf.selector);
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            1,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );
    }

    /**
     * @notice Test that amountToReturn > 0 triggers bridge to hub pool.
     */
    function testBridgeToHubPoolWithAmountToReturn() public {
        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(dataWorker);
        vm.expectEmit(true, true, true, true);
        emit BridgedToHubPool(1, address(destErc20));
        spokePool.distributeRelayerRefunds(destinationChainId, 1, emptyAmounts, 0, address(destErc20), emptyAddresses);
    }

    /**
     * @notice Test that amountToReturn = 0 does not trigger bridge to hub pool.
     */
    function testNoBridgeToHubPoolWithZeroAmountToReturn() public {
        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        // This should NOT emit BridgedToHubPool
        vm.prank(dataWorker);
        vm.recordLogs();
        spokePool.distributeRelayerRefunds(destinationChainId, 0, emptyAmounts, 0, address(destErc20), emptyAddresses);

        // Verify no BridgedToHubPool event was emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            assertFalse(
                entries[i].topics[0] == keccak256("BridgedToHubPool(uint256,address)"),
                "BridgedToHubPool should not be emitted"
            );
        }
    }

    /**
     * @notice Test that insufficient spoke pool balance reverts.
     */
    function testInsufficientSpokePoolBalance() public {
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_HELD_BY_POOL; // More than pool has
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InsufficientSpokePoolBalanceToExecuteLeaf.selector);
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            1,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );
    }

    // ============ Mixed Solana/EVM Leaves Tests ============

    /**
     * @notice Helper to build a merkle tree with multiple leaves.
     * @dev Returns the root and proofs for each leaf.
     */
    function _buildMultiLeafTree(
        SpokePoolInterface.RelayerRefundLeaf[] memory leaves
    ) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 n = leaves.length;
        bytes32[] memory hashes = new bytes32[](n);

        // Hash all leaves
        for (uint256 i = 0; i < n; i++) {
            hashes[i] = _hashLeaf(leaves[i]);
        }

        // Build the merkle tree (simplified for small trees)
        // For a tree with n leaves, we build level by level
        bytes32[] memory currentLevel = hashes;
        bytes32[][] memory levels = new bytes32[][](10); // Max 10 levels
        uint256 levelCount = 0;
        levels[levelCount++] = currentLevel;

        while (currentLevel.length > 1) {
            uint256 nextLevelSize = (currentLevel.length + 1) / 2;
            bytes32[] memory nextLevel = new bytes32[](nextLevelSize);

            for (uint256 i = 0; i < nextLevelSize; i++) {
                uint256 left = i * 2;
                uint256 right = left + 1;

                if (right >= currentLevel.length) {
                    // Odd number of elements, promote the last one
                    nextLevel[i] = currentLevel[left];
                } else {
                    // Sort and hash
                    if (uint256(currentLevel[left]) < uint256(currentLevel[right])) {
                        nextLevel[i] = keccak256(abi.encodePacked(currentLevel[left], currentLevel[right]));
                    } else {
                        nextLevel[i] = keccak256(abi.encodePacked(currentLevel[right], currentLevel[left]));
                    }
                }
            }
            currentLevel = nextLevel;
            levels[levelCount++] = currentLevel;
        }

        root = currentLevel[0];

        // Build proofs for each leaf
        proofs = new bytes32[][](n);
        for (uint256 leafIdx = 0; leafIdx < n; leafIdx++) {
            bytes32[] memory proof = new bytes32[](levelCount - 1);
            uint256 idx = leafIdx;

            for (uint256 level = 0; level < levelCount - 1; level++) {
                uint256 siblingIdx = (idx % 2 == 0) ? idx + 1 : idx - 1;

                if (siblingIdx < levels[level].length) {
                    proof[level] = levels[level][siblingIdx];
                } else {
                    // No sibling, use current node as sibling (will be filtered out)
                    proof[level] = levels[level][idx];
                }

                idx = idx / 2;
            }
            proofs[leafIdx] = proof;
        }
    }

    /**
     * @notice Test executing relayer refund root with mixed Solana and EVM leaves.
     * @dev This simulates a merkle tree containing both Solana leaves (different chain ID)
     * and EVM leaves (matching chain ID). Only EVM leaves should be successfully executed.
     */
    function testExecuteRelayerRefundWithMixedLeaves() public {
        // Create an array of leaves - alternating between EVM (matching chain) and "Solana" (different chain)
        SpokePoolInterface.RelayerRefundLeaf[] memory leaves = new SpokePoolInterface.RelayerRefundLeaf[](4);

        // Solana chain ID (different from destinationChainId)
        uint256 solanaChainId = 999999;

        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        // Leaf 0: Solana leaf (wrong chain ID)
        leaves[0] = _createLeaf(solanaChainId, 0, address(destErc20), emptyAddresses, emptyAmounts, 0);

        // Leaf 1: EVM leaf (correct chain ID) - refund to relayer
        address[] memory relayerAddresses = new address[](1);
        relayerAddresses[0] = relayer;
        uint256[] memory relayerAmounts = new uint256[](1);
        relayerAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        leaves[1] = _createLeaf(destinationChainId, 0, address(destErc20), relayerAddresses, relayerAmounts, 1);

        // Leaf 2: Solana leaf (wrong chain ID)
        leaves[2] = _createLeaf(solanaChainId, 0, address(destErc20), emptyAddresses, emptyAmounts, 2);

        // Leaf 3: EVM leaf (correct chain ID) - refund to rando
        address[] memory randoAddresses = new address[](1);
        randoAddresses[0] = rando;
        uint256[] memory randoAmounts = new uint256[](1);
        randoAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        leaves[3] = _createLeaf(destinationChainId, 0, address(destErc20), randoAddresses, randoAmounts, 3);

        // Build merkle tree
        (bytes32 root, bytes32[][] memory proofs) = _buildMultiLeafTree(leaves);

        // Relay the root bundle
        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        uint256 spokePoolBalanceBefore = destErc20.balanceOf(address(spokePool));

        // Execute only EVM leaves (skip Solana leaves which have wrong chain ID)
        // Leaf 1 (EVM)
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[1], proofs[1]);

        // Leaf 3 (EVM)
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[3], proofs[3]);

        // Verify correct amounts were distributed
        // Only 2 leaves executed, each with AMOUNT_TO_RELAY
        uint256 totalRefunded = SpokePoolUtils.AMOUNT_TO_RELAY * 2;
        assertEq(destErc20.balanceOf(address(spokePool)), spokePoolBalanceBefore - totalRefunded);
        assertEq(destErc20.balanceOf(relayer), SpokePoolUtils.AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);

        // Attempting to execute Solana leaves should revert with InvalidChainId
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidChainId.selector);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proofs[0]);

        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidChainId.selector);
        spokePool.executeRelayerRefundLeaf(0, leaves[2], proofs[2]);
    }

    /**
     * @notice Test executing relayer refund root with sorted Solana and EVM leaves.
     * @dev Similar to mixed test, but leaves are sorted (all Solana first, then all EVM).
     */
    function testExecuteRelayerRefundWithSortedLeaves() public {
        // Create an array of leaves - sorted (Solana first, then EVM)
        SpokePoolInterface.RelayerRefundLeaf[] memory leaves = new SpokePoolInterface.RelayerRefundLeaf[](4);

        // Solana chain ID (different from destinationChainId)
        uint256 solanaChainId = 999999;

        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        // Leaves 0-1: Solana leaves (wrong chain ID)
        leaves[0] = _createLeaf(solanaChainId, 0, address(destErc20), emptyAddresses, emptyAmounts, 0);
        leaves[1] = _createLeaf(solanaChainId, 0, address(destErc20), emptyAddresses, emptyAmounts, 1);

        // Leaf 2: EVM leaf (correct chain ID) - refund to relayer
        address[] memory relayerAddresses = new address[](1);
        relayerAddresses[0] = relayer;
        uint256[] memory relayerAmounts = new uint256[](1);
        relayerAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        leaves[2] = _createLeaf(destinationChainId, 0, address(destErc20), relayerAddresses, relayerAmounts, 2);

        // Leaf 3: EVM leaf (correct chain ID) - refund to rando
        address[] memory randoAddresses = new address[](1);
        randoAddresses[0] = rando;
        uint256[] memory randoAmounts = new uint256[](1);
        randoAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        leaves[3] = _createLeaf(destinationChainId, 0, address(destErc20), randoAddresses, randoAmounts, 3);

        // Build merkle tree
        (bytes32 root, bytes32[][] memory proofs) = _buildMultiLeafTree(leaves);

        // Relay the root bundle
        vm.prank(dataWorker);
        spokePool.relayRootBundle(root, mockSlowRelayRoot);

        uint256 spokePoolBalanceBefore = destErc20.balanceOf(address(spokePool));

        // Execute only EVM leaves (indices 2 and 3)
        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[2], proofs[2]);

        vm.prank(dataWorker);
        spokePool.executeRelayerRefundLeaf(0, leaves[3], proofs[3]);

        // Verify correct amounts were distributed
        uint256 totalRefunded = SpokePoolUtils.AMOUNT_TO_RELAY * 2;
        assertEq(destErc20.balanceOf(address(spokePool)), spokePoolBalanceBefore - totalRefunded);
        assertEq(destErc20.balanceOf(relayer), SpokePoolUtils.AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);

        // Verify Solana leaves cannot be executed (wrong chain ID)
        vm.prank(dataWorker);
        vm.expectRevert(V3SpokePoolInterface.InvalidChainId.selector);
        spokePool.executeRelayerRefundLeaf(0, leaves[0], proofs[0]);
    }

    // ============ Additional Missing Tests ============

    /**
     * @notice Test that TokensBridged event is emitted when amountToReturn > 0.
     */
    function testTokensBridgedEmitted() public {
        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        uint256 amountToReturn = 1 ether;

        vm.prank(dataWorker);
        vm.expectEmit(true, true, true, true);
        emit TokensBridged(
            amountToReturn,
            destinationChainId,
            0, // leafId
            address(destErc20).toBytes32(),
            dataWorker
        );
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            amountToReturn,
            emptyAmounts,
            0,
            address(destErc20),
            emptyAddresses
        );
    }

    /**
     * @notice Test that TokensBridged event is NOT emitted when amountToReturn = 0.
     */
    function testTokensBridgedNotEmittedOnZeroAmount() public {
        address[] memory emptyAddresses = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(dataWorker);
        vm.recordLogs();
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            0, // amountToReturn = 0
            emptyAmounts,
            0,
            address(destErc20),
            emptyAddresses
        );

        // Verify no TokensBridged event was emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            assertFalse(
                entries[i].topics[0] == keccak256("TokensBridged(uint256,uint256,uint32,bytes32,address)"),
                "TokensBridged should not be emitted"
            );
        }
    }

    /**
     * @notice Test that one Transfer event is emitted per nonzero refundAmount.
     * @dev This verifies that only addresses with nonzero amounts receive transfers.
     */
    function testTransferPerNonzeroRefund() public {
        address[] memory refundAddresses = new address[](3);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;
        refundAddresses[2] = makeAddr("thirdParty");

        uint256[] memory refundAmounts = new uint256[](3);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = 0; // Zero amount, should NOT trigger transfer
        refundAmounts[2] = SpokePoolUtils.AMOUNT_TO_RELAY;

        uint256 relayerBalanceBefore = destErc20.balanceOf(relayer);
        uint256 randoBalanceBefore = destErc20.balanceOf(rando);
        uint256 thirdPartyBalanceBefore = destErc20.balanceOf(refundAddresses[2]);

        vm.prank(dataWorker);
        vm.recordLogs();
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            0, // amountToReturn
            refundAmounts,
            0, // leafId
            address(destErc20),
            refundAddresses
        );

        // Count Transfer events
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 transferCount = 0;
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == transferTopic) {
                transferCount++;
            }
        }

        // Should only have 2 Transfer events (relayer and thirdParty, not rando)
        assertEq(transferCount, 2, "Should have exactly 2 Transfer events");

        // Verify balances
        assertEq(destErc20.balanceOf(relayer), relayerBalanceBefore + SpokePoolUtils.AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(rando), randoBalanceBefore); // No change
        assertEq(destErc20.balanceOf(refundAddresses[2]), thirdPartyBalanceBefore + SpokePoolUtils.AMOUNT_TO_RELAY);
    }
}
