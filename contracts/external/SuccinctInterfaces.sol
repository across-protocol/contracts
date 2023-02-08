pragma solidity ^0.8.0;

// These interfaces are a subset of the Succinct interfaces here: https://github.com/succinctlabs/telepathy-contracts.

// This interface should be implemented by any contract wanting to receive messages sent over the Succinct bridge.
interface ITelepathyHandler {
    function handleTelepathy(
        uint16 _sourceChainId,
        address _senderAddress,
        bytes memory _data
    ) external;
}

// This interface represents the contract that we call into to send messages over the Succinct AMB.
interface ITelepathyBroadcaster {
    function send(
        uint16 _recipientChainId,
        address _recipientAddress,
        bytes calldata _data
    ) external returns (bytes32);
}
