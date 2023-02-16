// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract TelepathyHandlerMock {
    function handleTelepathy(
        uint16 _sourceChainId,
        address _senderAddress,
        bytes memory _data
    ) external {}
}

contract TelepathyBroadcasterMock {
    function send(
        uint16 _recipientChainId,
        address _recipientAddress,
        bytes calldata _data
    ) external returns (bytes32) {
        return bytes32(0);
    }
}
