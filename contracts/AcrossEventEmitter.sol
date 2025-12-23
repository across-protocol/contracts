// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title AcrossEventEmitter
 * @notice A simple contract that emits events with bytes encoded metadata
 */
contract AcrossEventEmitter {
    /**
     * @notice Emitted when metadata is stored
     * @param data The metadata bytes emitted
     */
    event MetadataEmitted(bytes data);

    /**
     * @notice Emits metadata as an event
     * @param data The bytes data to emit
     */
    function emitData(bytes calldata data) external {
        require(data.length > 0, "Data cannot be empty");
        emit MetadataEmitted(data);
    }
}
