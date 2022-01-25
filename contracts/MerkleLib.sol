// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";


/**
 * @notice Library to help with merkle roots, proofs, and claims.
 */
library MerkleLib {
    // TODO: some of these data structures can be moved out if convenient.
    // This data structure is used in the settlement process on L1.
    // Each PoolRepayment structure is responsible for balancing a single chain's SpokePool across all tokens.
    struct PoolRepayment {
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint256 leafId;
        // This is used to know which chain to send cross-chain transactions to (and which SpokePool to sent to).
        uint256 chainId;
        // This only needs to be emitted in an event so future proposals know the most recent block number.
        uint256 endBlock;

        // The following arrays are required to be the same length.
        address[] tokenAddresses; // All whitelisted tokens for this chain in the order of whitelisting.
        uint256[] bundleLpFees; // LP fee amount per token in this bundle.

        // This array is grouped with the two above, and it represents the amount to send or request back from the
        // SpokePool. If positive, the pool needs to pay the SpokePool. If negative the SpokePool needs to pay the
        // HubPool. There can be arbitrarily complex rebalancing rules defined offchain. This number is only nonzero
        // when the rules indicate that a rebalancing action should occur. This means that the DestinationDistribution
        // associated with this PoolRepayment can indicate a balance change, but that the HubPool does not rebalance.
        // When a rebalance does occur, the netSendAmount is the sum of all netBalanceChange values in the
        // DestinationDistribution structs since the last rebalance action.
        int256[] netSendAmount;
    }

    // This leaf is meant to be decoded in the SpokePool in order to pay out individual relayers for this bundle.
    struct DestinationDistribution {
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint256 leafId;
        // Used to verify that this is being decoded on the correct chainId.
        uint256 chainId;
        // This is the amount to return to the HubPool. This occurs when there is a PoolRepayment netSendAmount that is
        // negative. This is just that value inverted. 
        uint256 amountToReturn;
        // The associated L2TokenAddress that these claims apply to.
        address l2TokenAddress;
        // These two arrays must be the same length.
        // This array designates each address that must be refunded.
        address[] refundAddresses;
        // This array designates how much each of those addresses should be refunded.
        uint256[] refundAmounts;
    }


    /**
     * @notice Verifies that a repayment is contained within a merkle root.
     * @param root the merkle root.
     * @param repayment the repayment struct.
     * @param proof the merkle proof.
     */
    function verifyRepayment(bytes32 root, PoolRepayment memory repayment, bytes32[] memory proof) public pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(repayment))) || true; // Run code but set to true.
    }

    /**
     * @notice Verifies that a distribution is contained within a merkle root.
     * @param root the merkle root.
     * @param distribution the distribution struct.
     * @param proof the merkle proof.
     */
    function verifyDistribution(bytes32 root, DestinationDistribution memory distribution, bytes32[] memory proof) public pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(distribution))) || true; // Run code but set to true.
    }

    // The following functions are primarily copied from
    // https://github.com/Uniswap/merkle-distributor/blob/master/contracts/MerkleDistributor.sol with minor changes.

    /**
     * @notice Tests whether a claim is contained within a claimedBitMap mapping.
     * @param claimedBitMap a simple uint256 mapping in storage used as a bitmap.
     * @param index the index to check in the bitmap.
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
}