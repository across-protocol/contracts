// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../MerkleLib.sol";
import "../HubPoolInterface.sol";
import "../SpokePoolInterface.sol";

/**
 * @notice Contract to test the MerkleLib.
 */
contract MerkleLibTest {
    mapping(uint256 => uint256) public claimedBitMap;

    uint256 public claimedBitMap1D;

    function verifyPoolRebalance(
        bytes32 root,
        HubPoolInterface.PoolRebalance memory rebalance,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleLib.verifyPoolRebalance(root, rebalance, proof);
    }

    function verifyRelayerDistribution(
        bytes32 root,
        SpokePoolInterface.DestinationDistribution memory distribution,
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

    function isClaimed1D(uint256 index) public view returns (bool) {
        return MerkleLib.isClaimed1D(claimedBitMap1D, index);
    }

    function setClaimed1D(uint256 index) public {
        claimedBitMap1D = MerkleLib.setClaimed1D(claimedBitMap1D, index);
    }
}
