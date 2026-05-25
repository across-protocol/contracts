// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualImplementation
 * @notice Interface for merkle leaf implementation contracts called by the CounterfactualDeposit dispatcher.
 * @dev Implementations are invoked via delegatecall from the clone, so `address(this)` is the clone address
 *      and `msg.sender` is the original caller. The dispatcher forwards the clone-identity fields impls
 *      may need — `recipient`, `outputToken`, `destinationChainId`, `userAddress` — after verifying them
 *      via the clone's stored `argsHash`. `routePolicyAddress` stays inside the dispatcher.
 *
 *      `userAddress` is forwarded so impls can pin a clone-bound destination and / or allow the user
 *      direct execution authority. `WithdrawImplementation` uses it as the forced withdrawal
 *      destination and as one of two authorized callers (the other is its own immutable admin).
 *      Bridge impls ignore it.
 */
interface ICounterfactualImplementation {
    /**
     * @notice Execute the implementation logic.
     * @param recipient Destination-chain address that receives `outputToken` (from `cloneArgs.recipient`).
     * @param outputToken Token received on the destination chain (from `cloneArgs.outputToken`).
     * @param destinationChainId Destination chain ID (from `cloneArgs.destinationChainId`).
     * @param userAddress Clone user address (from `cloneArgs.userAddress`). Impls that need to send
     *                    funds to the user or gate execution on the user's address use this.
     * @param routeParams ABI-encoded route parameters committed to in the merkle leaf.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address userAddress,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) external payable;
}
