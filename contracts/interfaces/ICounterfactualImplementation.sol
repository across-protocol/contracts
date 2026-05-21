// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualImplementation
 * @notice Interface for merkle leaf implementation contracts called by the CounterfactualDeposit dispatcher.
 * @dev Implementations are invoked via delegatecall from the clone, so `address(this)` is the clone address
 *      and `msg.sender` is the original caller. The dispatcher forwards only the clone-identity fields the
 *      impl needs — `recipient`, `outputToken`, `destinationChainId` — after verifying them via the clone's
 *      stored `argsHash`. Identity fields not relevant to the bridge call (e.g. `withdrawUser`,
 *      `routePolicyAddress`) stay inside the dispatcher and are not forwarded.
 */
interface ICounterfactualImplementation {
    /**
     * @notice Execute the implementation logic.
     * @param recipient Destination-chain address that receives `outputToken` (from `cloneArgs.recipient`).
     * @param outputToken Token received on the destination chain (from `cloneArgs.outputToken`).
     * @param destinationChainId Destination chain ID (from `cloneArgs.destinationChainId`).
     * @param routeParams ABI-encoded route parameters committed to in the merkle leaf.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) external payable;
}
