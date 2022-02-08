// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @notice Library to help with merkle roots, proofs, and claims.
 */
library MerkleLib {
    // TODO: some of these data structures can be moved out if convenient.
    // This data structure is used in the settlement process on L1.
    // Each PoolRebalance structure is responsible for balancing a single chain's SpokePool across all tokens.
    struct PoolRebalance {
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint256 leafId;
        // This is used to know which chain to send cross-chain transactions to (and which SpokePool to sent to).
        uint256 chainId;
        // The following arrays are required to be the same length. They are parallel arrays for the given chainId and should be ordered by the `l1Tokens` field.
        // All whitelisted tokens with nonzero relays on this chain in this bundle in the order of whitelisting.
        address[] l1Tokens;
        uint256[] bundleLpFees; // Total LP fee amount per token in this bundle, encompassing all associated bundled relays.
        // This array is grouped with the two above, and it represents the amount to send or request back from the
        // SpokePool. If positive, the pool will pay the SpokePool. If negative the SpokePool will pay the HubPool.
        // There can be arbitrarily complex rebalancing rules defined offchain. This number is only nonzero
        // when the rules indicate that a rebalancing action should occur. When a rebalance does not occur,
        // runningBalances for this token should change by the total relays - deposits in this bundle. When a rebalance
        // does occur, runningBalances should be set to zero for this token and the netSendAmounts should be set to the
        // previous runningBalances + relays - deposits in this bundle.
        int256[] netSendAmounts;
        // This is only here to be emitted in an event to track a running unpaid balance between the L2 pool and the L1 pool.
        // A positive number indicates that the HubPool owes the SpokePool funds. A negative number indicates that the

        // SpokePool owes the HubPool funds. See the comment above for the dynamics of this and netSendAmounts
        int256[] runningBalances;
    }

    // This leaf is meant to be decoded in the SpokePool in order to pay out individual relayers for this bundle.
    struct DestinationDistribution {
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint256 leafId;
        // Used to verify that this is being decoded on the correct chainId.
        uint256 chainId;
        // This is the amount to return to the HubPool. This occurs when there is a PoolRebalance netSendAmount that is
        // negative. This is just that value inverted.
        uint256 amountToReturn;
        // The associated L2TokenAddress that these claims apply to.
        address l2TokenAddress;
        // These two arrays must be the same length and are parallel arrays. They should be order by refundAddresses.
        // This array designates each address that must be refunded.
        address[] refundAddresses;
        // This array designates how much each of those addresses should be refunded.
        uint256[] refundAmounts;
    }

    /**
     * @notice Verifies that a repayment is contained within a merkle root.
     * @param root the merkle root.
     * @param rebalance the rebalance struct.
     * @param proof the merkle proof.
     */
    function verifyPoolRebalance(
        bytes32 root,
        PoolRebalance memory rebalance,
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
        DestinationDistribution memory distribution,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(distribution)));
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
}
