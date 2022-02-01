// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../MerkleLib.sol";

/**
 * @notice Contract to test the MerkleLib.
 */
contract MerkleLibTest {
    mapping(uint256 => uint256) public claimedBitMap;

    function verifyPoolRebalance(
        bytes32 root,
        MerkleLib.PoolRebalance memory rebalance,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleLib.verifyPoolRebalance(root, rebalance, proof);
    }

    function verifyRelayerDistribution(
        bytes32 root,
        MerkleLib.DestinationDistribution memory distribution,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleLib.verifyRelayerDistribution(root, distribution, proof);
    }

    function isClaimed(uint256 index) public view returns (bool) {
        return MerkleLib.isClaimed(claimedBitMap, index);
    }

    function setClaimed(uint256 index) public {
        MerkleLib.setClaimed(claimedBitMap, index);
    }
}
