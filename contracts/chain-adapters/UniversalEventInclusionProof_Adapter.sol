// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

/**
 * @notice Adapter to be used to relay messages to L2 SpokePools that have light client and verification contracts
 * that can verify event inclusion proofs. This adapter essentially performs a no-op when relayMessage is called,
 * and takes advantage of the fact that an ExecutedRootBundle event will be emitted on the L1 HubPool contract
 * that will contain the data that needs to be relayed to the L2 SpokePool.
 */
contract UniversalEventInclusionProof_Adapter is AdapterInterface {
    error NotImplemented();

    /**
     * @notice Does nothing, as the ExecutedRootBundle event inclusion can be proven on the L2.
     */
    function relayMessage(address, bytes calldata) external payable override {
        // This method is intentionally left as a no-op.
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
