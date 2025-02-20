// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// This interface is expected to be implemented by any contract that expects to receive messages from the SpokePool.
interface AcrossMessageHandler {
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address relayer,
        bytes memory message
    ) external;
}
