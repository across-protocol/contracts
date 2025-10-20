// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title AcrossEventEmitter
 * @notice A simple contract that emits events with bytes encoded metadata
 */
contract AcrossEventEmitter is ReentrancyGuard {
    /**
     * @notice Emitted when metadata is stored
     * @param data The metadata bytes emitted
     */
    event MetadataEmitted(bytes data);

    /**
     * @notice Prevents native token from being sent to this contract
     */
    receive() external payable {
        revert("Contract does not accept native token");
    }

    /**
     * @notice Prevents native token from being sent to this contract via fallback
     */
    fallback() external payable {
        revert("Contract doesn't accept native token");
    }

    /**
     * @notice Emits metadata as an event
     * @param data The bytes data to emit
     */
    function emitData(bytes calldata data) external nonReentrant {
        require(data.length > 0, "Data cannot be empty");
        emit MetadataEmitted(data);
    }
}
