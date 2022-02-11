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

    function verifyPoolRebalanceLeaf(
        bytes32 root,
        HubPoolInterface.PoolRebalanceLeaf memory rebalance,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleLib.verifyPoolRebalanceLeaf(root, rebalance, proof);
    }

    function verifyRelayerDistribution(
        bytes32 root,
        SpokePoolInterface.DestinationDistributionLeaf memory distribution,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleLib.verifyRelayerDistribution(root, distribution, proof);
    }

    function verifySlowRelayFulfillment(
        bytes32 root,
        SpokePoolInterface.RelayData memory slowRelayFulfillment,
        bytes32[] memory proof
    ) public pure returns (bool) {
        return MerkleLib.verifySlowRelayFulfillment(root, slowRelayFulfillment, proof);
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
