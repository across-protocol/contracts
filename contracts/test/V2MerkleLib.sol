// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/MockV2SpokePoolInterface.sol";

/**
 * @notice Library to help with merkle roots, proofs, and claims.
 */
library V2MerkleLib {
    function verifySlowRelayFulfillment(
        bytes32 root,
        MockV2SpokePoolInterface.SlowFill memory slowRelayFulfillment,
        bytes32[] memory proof
    ) internal pure returns (bool) {
        return MerkleProof.verify(proof, root, keccak256(abi.encode(slowRelayFulfillment)));
    }
}
