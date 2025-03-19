// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IHelios } from "../external/interfaces/ISP1Helios.sol";
import { Encoding } from "../external/Steel.sol";

/// @title HeliosSteelValidator
/// @notice Validates Steel commitments using the Helios light client
/// @dev Only supports Steel Beacon Commitments
/// @dev Inspired by https://github.com/risc0/risc0-ethereum/blob/v1.4.0/contracts/src/steel/Steel.sol
contract HeliosSteelValidator {
    /// @notice Represents a commitment to a specific block in the blockchain.
    /// @dev The `id` combines the version and the actual identifier of the claim, such as the block number.
    /// @dev The `digest` represents the data being committed to, e.g. the hash of the execution block.
    /// @dev The `configID` is the cryptographic digest of the network configuration.
    struct Commitment {
        uint256 id;
        bytes32 digest;
        bytes32 configID;
    }

    error InvalidCommitmentVersion();
    error InvalidCommitmentTimestamp();

    // @notice Helios light client
    IHelios public immutable helios;

    /// @notice Constructs a new HeliosSteelValidator
    /// @param _helios Address of the SP1Helios light client
    constructor(address _helios) {
        helios = IHelios(_helios);
    }

    /// @notice Validates a Steel commitment
    /// @param commitment The commitment to validate
    /// @return True if the commitment is valid
    function validateCommitment(Commitment calldata commitment) external view returns (bool) {
        (uint240 blockID, uint16 version) = Encoding.decodeVersionedID(commitment.id);
        if (version != 1) {
            revert InvalidCommitmentVersion();
        }

        return validateLightClientCommitment(blockID, commitment.digest);
    }

    /// @notice Validates a light client commitment
    /// @param timestamp The timestamp associated with the commitment
    /// @param parentRoot The expected parent beacon block root
    /// @return True if the commitment is valid
    function validateLightClientCommitment(uint256 timestamp, bytes32 parentRoot) internal view returns (bool) {
        uint256 genesisTime = helios.GENESIS_TIME();
        if (timestamp < genesisTime) {
            revert InvalidCommitmentTimestamp();
        }
        // Compute the slot corresponding to the commitment's timestamp
        uint256 slot = (timestamp - genesisTime) / helios.SECONDS_PER_SLOT();

        // Iterate backwards to locate the expected parent block
        while (slot > 0) {
            slot--;
            bytes32 headerRoot = helios.headers(slot);
            // Skip missed slots (empty roots)
            if (headerRoot == bytes32(0)) {
                continue;
            }
            return (headerRoot == parentRoot);
        }

        return false;
    }
}
