// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/SuccinctInterfaces.sol";

// solhint-disable-next-line contract-name-camelcase
contract Succinct_Adapter is AdapterInterface {
    ITelepathyBroadcaster public immutable succinctSourceAmb;
    uint16 public immutable destinationChainId;

    // Special Succinct event for additional tracking information.
    event SuccinctMessageRelayed(bytes32 messageRoot, uint16 destinationChainId, address target, bytes message);

    /**
     * @notice Constructs new Adapter.
     * @param _succinctSourceAmb address of the SourceAmb succinct contract for sending messages.
     * @param _destinationChainId chainId of the destination.
     */
    constructor(ITelepathyBroadcaster _succinctSourceAmb, uint16 _destinationChainId) {
        succinctSourceAmb = _succinctSourceAmb;
        destinationChainId = _destinationChainId;
    }

    /**
     * @notice Send cross-chain message to target on the destination.
     * @param target Contract on the destinatipn that will receive the message..
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        bytes32 messageRoot = succinctSourceAmb.send(destinationChainId, target, message);

        // Note: this emits two events. MessageRelayed for the sake of compatibility with other adapters.
        // It emits SuccinctMessageRelayed to encode additional tracking information that is Succinct-specific.
        emit MessageRelayed(target, message);
        emit SuccinctMessageRelayed(messageRoot, destinationChainId, target, message);
    }

    /**
     * @notice No-op relay tokens method.
     */
    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        // This method is intentionally left as a no-op.
        // If the adapter is intended to be able to relay tokens, this method should be overriden.
    }
}
