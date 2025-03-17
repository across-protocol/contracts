// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

/**
 * @notice Adapter to be used to relay messages to L2 SpokePools that have light client and verification contracts
 * that can verify event inclusion proofs.
 */
contract UniversalEventInclusionProof_Adapter is AdapterInterface {
    error NotImplemented();

    event RelayedMessage(address indexed target, bytes message);

    /**
     * @notice Emits an event containing the message that we can submit to the target spoke pool via
     * event inclusion proof.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        emit RelayedMessage(target, message);
    }

    /**
     * @notice No-op relay tokens method, reverts because it should not be called.
     */
    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        // If the adapter is intended to be able to relay tokens, this method should be overridden.
        revert NotImplemented();
    }
}
