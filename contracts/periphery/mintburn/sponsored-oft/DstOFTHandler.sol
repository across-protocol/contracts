// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ILayerZeroComposer } from "../../../external/interfaces/ILayerZeroComposer.sol";

contract DstOFTHandler is ILayerZeroComposer {
    address public immutable endpoint;
    address public immutable oApp;

    constructor(address _endpoint, address _oApp) {
        endpoint = _endpoint;
        oApp = _oApp;
    }

    /**
     * @notice Handles incoming composed messages from LayerZero.
     * @dev Ensures the message comes from the correct OApp and is sent through the authorized endpoint.
     *
     * @param _oApp The address of the OApp that is sending the composed message.
     */
    function lzCompose(
        address _oApp,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override {
        require(_oApp == oApp, "ComposedReceiver: Invalid OApp");
        require(msg.sender == endpoint, "ComposedReceiver: Unauthorized sender");

        // TODO: decode _composeMsg via ComposeMsgLib
        // TODO: decode _composeMsg.message: the one we sent from SRC
        // TODO: validate signature. How? 2 options:
        // TODO:   1. check the SRC sender contract against a mapping
        // TODO:   2. check the signature against the params that are available

        // TODO! For OFT, most likely we don't have access to original `amount`, only the amount
        // TODO! that just arrived with the current OFT TX. So we omit sponsoring the bridge amount.
        // TODO! All we _are_ sponsoring is the swap. For this, we need to enqueue the correct limit order
    }
}
