// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

contract TelepathyBroadcasterMock {
    function send(
        uint16,
        address,
        bytes calldata
    ) external pure returns (bytes32) {
        return bytes32(0);
    }
}
