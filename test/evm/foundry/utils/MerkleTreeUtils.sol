// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

/**
 * @title MerkleTreeUtils
 * @notice Utility functions for building Merkle trees in Foundry tests.
 * @dev Provides both single-leaf helpers (root = hash of leaf, empty proof) and
 *      multi-leaf tree building with proof generation (OpenZeppelin sorted pair hashing).
 */
library MerkleTreeUtils {
    // ============ Multi-Leaf Tree Building ============

    /**
     * @notice Builds a Merkle tree from an array of leaf hashes.
     * @param leaves Array of leaf hashes (must be power of 2 or will be padded)
     * @return root The Merkle root
     * @return tree The full tree (layer by layer, leaves first)
     */
    function buildTree(bytes32[] memory leaves) internal pure returns (bytes32 root, bytes32[] memory tree) {
        require(leaves.length > 0, "Empty leaves array");

        if (leaves.length == 1) {
            tree = new bytes32[](1);
            tree[0] = leaves[0];
            return (leaves[0], tree);
        }

        // Pad to power of 2 if needed
        uint256 n = leaves.length;
        uint256 paddedLength = 1;
        while (paddedLength < n) {
            paddedLength *= 2;
        }

        bytes32[] memory paddedLeaves = new bytes32[](paddedLength);
        for (uint256 i = 0; i < n; i++) {
            paddedLeaves[i] = leaves[i];
        }
        // Pad with zero hashes (empty nodes)
        for (uint256 i = n; i < paddedLength; i++) {
            paddedLeaves[i] = bytes32(0);
        }

        // Calculate total tree size: sum of all layers = 2*paddedLength - 1
        uint256 treeSize = 2 * paddedLength - 1;
        tree = new bytes32[](treeSize);

        // Copy leaves to tree (bottom layer)
        for (uint256 i = 0; i < paddedLength; i++) {
            tree[i] = paddedLeaves[i];
        }

        // Build tree bottom-up
        uint256 offset = 0;
        uint256 layerSize = paddedLength;
        uint256 nextOffset = paddedLength;

        while (layerSize > 1) {
            for (uint256 i = 0; i < layerSize; i += 2) {
                bytes32 left = tree[offset + i];
                bytes32 right = tree[offset + i + 1];
                // Sorted pair hashing (OpenZeppelin style)
                tree[nextOffset + i / 2] = hashPair(left, right);
            }
            offset = nextOffset;
            nextOffset = offset + layerSize / 2;
            layerSize = layerSize / 2;
        }

        root = tree[treeSize - 1];
    }

    /**
     * @notice Gets the Merkle proof for a leaf at a given index.
     * @param tree The full Merkle tree (from buildTree)
     * @param leafIndex The index of the leaf
     * @param numLeaves The original number of leaves (before padding)
     * @return proof The Merkle proof
     */
    function getProof(
        bytes32[] memory tree,
        uint256 leafIndex,
        uint256 numLeaves
    ) internal pure returns (bytes32[] memory proof) {
        require(leafIndex < numLeaves, "Leaf index out of bounds");

        // Calculate padded length
        uint256 paddedLength = 1;
        while (paddedLength < numLeaves) {
            paddedLength *= 2;
        }

        // Calculate proof length (tree depth)
        uint256 depth = 0;
        uint256 temp = paddedLength;
        while (temp > 1) {
            temp /= 2;
            depth++;
        }

        proof = new bytes32[](depth);

        uint256 offset = 0;
        uint256 layerSize = paddedLength;
        uint256 idx = leafIndex;

        for (uint256 i = 0; i < depth; i++) {
            // Get sibling index
            uint256 siblingIdx = idx % 2 == 0 ? idx + 1 : idx - 1;
            proof[i] = tree[offset + siblingIdx];

            // Move to next layer
            offset += layerSize;
            layerSize /= 2;
            idx /= 2;
        }
    }

    /**
     * @notice Hash a sorted pair of nodes (OpenZeppelin style).
     */
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        if (a <= b) {
            return keccak256(abi.encodePacked(a, b));
        } else {
            return keccak256(abi.encodePacked(b, a));
        }
    }

    // ============ Single-Leaf Helpers ============
    /**
     * @notice Builds a single-token pool rebalance leaf and its merkle root.
     * @param chainId The destination chain ID
     * @param token The L1 token address
     * @param netSendAmount Amount to send to L2 (positive = send to L2)
     * @param lpFee LP fee for this rebalance
     * @return leaf The pool rebalance leaf struct
     * @return root The merkle root (hash of the single leaf)
     */
    function buildSingleTokenLeaf(
        uint256 chainId,
        address token,
        uint256 netSendAmount,
        uint256 lpFee
    ) internal pure returns (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) {
        uint256[] memory bundleLpFees = new uint256[](1);
        bundleLpFees[0] = lpFee;

        int256[] memory netSendAmounts = new int256[](1);
        netSendAmounts[0] = int256(netSendAmount);

        int256[] memory runningBalances = new int256[](1);
        runningBalances[0] = int256(netSendAmount);

        address[] memory l1Tokens = new address[](1);
        l1Tokens[0] = token;

        leaf = HubPoolInterface.PoolRebalanceLeaf({
            chainId: chainId,
            groupIndex: 0,
            bundleLpFees: bundleLpFees,
            netSendAmounts: netSendAmounts,
            runningBalances: runningBalances,
            leafId: 0,
            l1Tokens: l1Tokens
        });

        root = keccak256(abi.encode(leaf));
    }

    /**
     * @notice Builds a multi-token pool rebalance leaf and its merkle root.
     * @param chainId The destination chain ID
     * @param tokens Array of L1 token addresses
     * @param netSendAmounts_ Array of amounts to send to L2 (positive = send to L2)
     * @param lpFees Array of LP fees for each token
     * @return leaf The pool rebalance leaf struct
     * @return root The merkle root (hash of the single leaf)
     */
    function buildMultiTokenLeaf(
        uint256 chainId,
        address[] memory tokens,
        uint256[] memory netSendAmounts_,
        uint256[] memory lpFees
    ) internal pure returns (HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32 root) {
        require(tokens.length == netSendAmounts_.length && tokens.length == lpFees.length, "Array length mismatch");

        int256[] memory netSendAmounts = new int256[](tokens.length);
        int256[] memory runningBalances = new int256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            netSendAmounts[i] = int256(netSendAmounts_[i]);
            runningBalances[i] = int256(netSendAmounts_[i]);
        }

        leaf = HubPoolInterface.PoolRebalanceLeaf({
            chainId: chainId,
            groupIndex: 0,
            bundleLpFees: lpFees,
            netSendAmounts: netSendAmounts,
            runningBalances: runningBalances,
            leafId: 0,
            l1Tokens: tokens
        });

        root = keccak256(abi.encode(leaf));
    }

    /**
     * @notice Returns an empty proof array for single-leaf trees.
     */
    function emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }
}
