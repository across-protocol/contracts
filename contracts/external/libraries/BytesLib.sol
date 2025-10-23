// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Bytes } from "@openzeppelin/contracts-v5/utils/Bytes.sol";

library BytesLib {
    /**************************************
     *              ERRORS                *
     **************************************/
    error OutOfBounds();

    /**************************************
     *              FUNCTIONS              *
     **************************************/

    // The following 4 functions are copied from solidity-bytes-utils library
    // https://github.com/GNSPS/solidity-bytes-utils/blob/fc502455bb2a7e26a743378df042612dd50d1eb9/contracts/BytesLib.sol#L323C5-L398C6
    // Code was copied, and slightly modified to use revert instead of require

    /**
     * @notice Reads a uint16 from a bytes array at a given start index
     * @param _bytes The bytes array to convert
     * @param _start The start index of the uint16
     * @return result The uint16 result
     */
    function toUint16(bytes memory _bytes, uint256 _start) internal pure returns (uint16 result) {
        if (_bytes.length < _start + 2) {
            revert OutOfBounds();
        }

        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := mload(add(add(_bytes, 0x2), _start))
        }
    }

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

    /**
     * @notice Reads a bytes array from a bytes array at a given start index and length
     * Source: OpenZeppelin Contracts v5 (utils/Bytes.sol)
     * @param _bytes The bytes array to convert
     * @param _start The start index of the bytes array
     * @param _end The end index of the bytes array
     * @return result The bytes array result
     */
    function slice(bytes memory _bytes, uint256 _start, uint256 _end) internal pure returns (bytes memory result) {
        return Bytes.slice(_bytes, _start, _end);
    }
}
