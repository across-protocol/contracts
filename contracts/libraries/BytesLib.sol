// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library BytesLib {
    /**************************************
     *              ERRORS                *
     **************************************/
    error OutOfBounds();

    /**************************************
     *              FUNCTIONS              *
     **************************************/

    /**
     * @notice Reads a uint32 from a bytes array at a given start index
     * @param _bytes The bytes array to convert
     * @param _start The start index of the uint32
     * @return result The uint32 result
     */
    function toUint32(bytes memory _bytes, uint256 _start) internal pure returns (uint32 result) {
        if (_bytes.length < _start + 4) {
            revert OutOfBounds();
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := mload(add(add(_bytes, 0x4), _start))
        }
    }

    /**
     * @notice Reads a uint256 from a bytes array at a given start index
     * @param _bytes The bytes array to convert
     * @param _start The start index of the uint256
     * @return result The uint256 result
     */
    function toUint256(bytes memory _bytes, uint256 _start) internal pure returns (uint256 result) {
        if (_bytes.length < _start + 32) {
            revert OutOfBounds();
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := mload(add(add(_bytes, 0x20), _start))
        }
    }

    /**
     * @notice Reads a bytes32 from a bytes array at a given start index
     * @param _bytes The bytes array to convert
     * @param _start The start index of the bytes32
     * @return result The bytes32 result
     */
    function toBytes32(bytes memory _bytes, uint256 _start) internal pure returns (bytes32 result) {
        if (_bytes.length < _start + 32) {
            revert OutOfBounds();
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := mload(add(add(_bytes, 0x20), _start))
        }
    }
}
