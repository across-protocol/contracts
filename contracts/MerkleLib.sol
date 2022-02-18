// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./SpokePoolInterface.sol";
import "./HubPoolInterface.sol";

/**
 * @notice Library to help with merkle roots, proofs, and claims.
 */
library MerkleLib {
    /**
     * @notice Verifies that a repayment is contained within a merkle root.
     * @param root the merkle root.
     * @param rebalance the rebalance struct.
     * @param proof the merkle proof.
     */
    function verifyPoolRebalance(
        bytes32 root,
        HubPoolInterface.PoolRebalanceLeaf memory rebalance,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(rebalance)));
    }

    /**
     * @notice Verifies that a distribution is contained within a merkle root.
     * @param root the merkle root.
     * @param distribution the distribution struct.
     * @param proof the merkle proof.
     */
    function verifyRelayerDistribution(
        bytes32 root,
        SpokePoolInterface.DestinationDistributionLeaf memory distribution,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(distribution)));
    }

    /**
     * @notice Verifies that a distribution is contained within a merkle root.
     * @param root the merkle root.
     * @param slowRelayFulfillment the relayData fulfullment struct.
     * @param proof the merkle proof.
     */
    function verifySlowRelayFulfillment(
        bytes32 root,
        SpokePoolInterface.RelayData memory slowRelayFulfillment,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(slowRelayFulfillment)));
    }

    // The following functions are primarily copied from
    // https://github.com/Uniswap/merkle-distributor/blob/master/contracts/MerkleDistributor.sol with minor changes.

    /**
     * @notice Tests whether a claim is contained within a claimedBitMap mapping.
     * @param claimedBitMap a simple uint256 mapping in storage used as a bitmap.
     * @param index the index to check in the bitmap.
     * @return bool indicating if the index within the claimedBitMap has been marked as claimed.
     */
    function isClaimed(mapping(uint256 => uint256) storage claimedBitMap, uint256 index) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[claimedWordIndex];
        uint256 mask = (1 << claimedBitIndex);
        return claimedWord & mask == mask;
    }

    /**
     * @notice Marks an index in a claimedBitMap as claimed.
     * @param claimedBitMap a simple uint256 mapping in storage used as a bitmap.
     * @param index the index to mark in the bitmap.
     */
    function setClaimed(mapping(uint256 => uint256) storage claimedBitMap, uint256 index) public {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[claimedWordIndex] = claimedBitMap[claimedWordIndex] | (1 << claimedBitIndex);
    }

    /**
     * @notice Tests whether a claim is contained within a 1D claimedBitMap mapping.
     * @param claimedBitMap a simple uint256 value, encoding a 1D bitmap.
     * @param index the index to check in the bitmap.
     \* @return bool indicating if the index within the claimedBitMap has been marked as claimed.
     */
    function isClaimed1D(uint256 claimedBitMap, uint256 index) public pure returns (bool) {
        uint256 mask = (1 << index);
        return claimedBitMap & mask == mask;
    }

    /**
     * @notice Marks an index in a claimedBitMap as claimed.
     * @param claimedBitMap a simple uint256 mapping in storage used as a bitmap.
     * @param index the index to mark in the bitmap.
     */
    function setClaimed1D(uint256 claimedBitMap, uint256 index) public pure returns (uint256) {
        require(index <= 255, "Index out of bounds");
        return claimedBitMap | (1 << index % 256);
    }

    function verifyNeighborhood(
        bytes32 root,
        bytes32[] memory leaves,
        bytes32[] calldata proof
    ) internal pure returns (bool) {
        // If the length is 1 (or 0) just skip the loop, since the node should just be verified directly.
        if (leaves.length > 1) {
            // The algorithm below successively reduces the merkle data (via hashing) to the earlier indexes.
            // As it goes, it replaces the indices that are no longer used with bytes32(0) so future iterations know
            // where the end of the usable data is.
            while (leaves[1] != bytes32(0)) {
                // Just increments. Relies on the break statement to terminate the loop.
                for (uint256 i = 0; ; i++) {
                    // Store this variable since this is needed twice.
                    bool isEven = i % 2 == 0;

                    // This just detects if this index is the end of the current data. That could be the end of the
                    // allocated array or the end of the nonzero data.
                    if (i == leaves.length - 1 || leaves[i + 1] == bytes32(0)) {
                        // If it's an even index, we need to just move up the data with no other modifications since
                        // there's no data to hash this node with.
                        if (isEven) {
                            // Note: this ordering is done specifically to avoid the case where i == i / 2. Deleting
                            // old data before setting new data avoids us accidentally removing the data we're trying
                            // to write.
                            bytes32 inode = leaves[i];
                            leaves[i] = bytes32(0);
                            leaves[i / 2] = inode;
                        }

                        // Note: do nothing if odd since the data has already been hashed with another node.
                        // Always break at the end of the usable data.
                        break;
                    } else {
                        // If even and not at the end, we combine the data with the next node to create the new inode.
                        if (isEven) {
                            // Note: this ordering is done specifically to avoid the case where i == i / 2. Deleting
                            // old data before setting new data avoids us accidentally removing the data we're trying
                            // to write.
                            bytes32 inode = keccak256(abi.encode(leaves[i], leaves[i + 1]));
                            leaves[i] = bytes32(0);
                            leaves[i + 1] = bytes32(0);
                            leaves[i / 2] = inode;
                        }
                    }
                }
            }
        }

        // Take leaves[0], which should be the only nonzero data point and verify it using the provided proof.
        return MerkleProof.verify(proof, root, leaves[0]);
    }
}
