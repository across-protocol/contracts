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
        if (leaves.length > 1) {
            while (leaves[1] != bytes32(0)) {
                for (uint256 i = 0; ; i++) {
                    bool isEven = i % 2 == 0;
                    if (i == leaves.length - 1 || leaves[i + 1] == bytes32(0)) {
                        if (isEven) {
                            leaves[i / 2] = leaves[i];
                        }
                        break;
                    } else {
                        if (isEven) {
                            leaves[i / 2] = keccak256(abi.encode(leaves[i], leaves[i + 1]));
                        }
                    }
                }
            }
        }

        return MerkleProof.verify(proof, root, leaves[0]);
    }
}
