// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library BytesLib {
    /**************************************
     *              ERRORS                *
     **************************************/
    error OutOfBounds();
    error InvalidBytes();
    error InvalidStart();

    /**************************************
     *              FUNCTIONS              *
     **************************************/

    /**
     * @notice Reads a uint16 from a bytes array at a given start index
     * @param _bytes The bytes array to convert
     * @param _start The start index of the uint16
     * @return result The uint16 result
     */
    function toUint16(bytes memory _bytes, uint256 _start) internal pure returns (uint16 result) {
        require(_bytes.length >= _start + 2, "toUint16_outOfBounds");

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
     * @param _bytes The bytes array to convert
     * @param _start The start index of the bytes array
     * @param _end The end index of the bytes array
     * @return result The bytes array result
     */
    function slice(bytes memory _bytes, uint256 _start, uint256 _end) internal pure returns (bytes memory result) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let l := mload(_bytes) // _bytes length.
            if iszero(gt(l, _end)) {
                _end := l
            }
            if iszero(gt(l, _start)) {
                _start := l
            }
            if lt(_start, _end) {
                result := mload(0x40)
                let n := sub(_end, _start)
                let i := add(_bytes, _start)
                let w := not(0x1f)
                // Copy the `_bytes` one word at a time, backwards.
                for {
                    let j := and(add(n, 0x1f), w)
                } 1 {} {
                    mstore(add(result, j), mload(add(i, j)))
                    j := add(j, w) // `sub(j, 0x20)`.
                    if iszero(j) {
                        break
                    }
                }
                let o := add(add(result, 0x20), n)
                mstore(o, 0) // Zeroize the slot after the bytes.
                mstore(0x40, add(o, 0x20)) // Allocate memory.
                mstore(result, n) // Store the length.
            }
        }
    }
}
