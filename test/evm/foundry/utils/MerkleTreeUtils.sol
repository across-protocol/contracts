// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

/**
 * @title MerkleTreeUtils
 * @notice Utility functions for building Merkle trees in Foundry tests.
 * @dev For simple single-leaf trees, the root is just the hash of the leaf with an empty proof.
 */
library MerkleTreeUtils {
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
