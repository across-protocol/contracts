// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualImplementation
 * @notice Interface for merkle leaf implementation contracts called by the CounterfactualDeposit dispatcher.
 * @dev Implementations are invoked via delegatecall from the clone, so `address(this)` is the clone address
 *      and `msg.sender` is the original caller. The dispatcher forwards the clone-identity fields impls
 *      may need — `recipient`, `outputToken`, `destinationChainId`, `admin` — after verifying them via
 *      the clone's stored `argsHash`. `routePolicyAddress` stays inside the dispatcher.
 *
 *      `admin` is forwarded so impls that depend on the dispatcher's admin escape for authorization
 *      (notably `WithdrawImplementation`) can independently verify `msg.sender == admin`. Bridge impls
 *      ignore it.
 */
interface ICounterfactualImplementation {
    /**
     * @notice Execute the implementation logic.
     * @param recipient Destination-chain address that receives `outputToken` (from `cloneArgs.recipient`).
     * @param outputToken Token received on the destination chain (from `cloneArgs.outputToken`).
     * @param destinationChainId Destination chain ID (from `cloneArgs.destinationChainId`).
     * @param admin Clone admin address (from `cloneArgs.admin`). Impls that need admin-only access
     *              check `msg.sender == admin`.
     * @param routeParams ABI-encoded route parameters committed to in the merkle leaf.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address admin,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) external payable;
}
