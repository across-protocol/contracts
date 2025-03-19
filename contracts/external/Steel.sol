// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Encoding Library, copied from https://github.com/risc0/risc0-ethereum/blob/95c71d5247216c80f95bf4d2cbf4408d7b384d1f/contracts/src/steel/Steel.sol#L91C1-L117C2
library Encoding {
    /// @notice Decodes a version and ID from a single uint256 value.
    /// @param id The single uint256 value to be decoded.
    /// @return Returns two values: a uint240 for the original base ID and a uint16 for the version number encoded into it.
    function decodeVersionedID(uint256 id) internal pure returns (uint240, uint16) {
        uint240 decoded;
        uint16 version;
        assembly {
            decoded := and(id, 0x0000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            version := shr(240, id)
        }
        return (decoded, version);
    }
}
