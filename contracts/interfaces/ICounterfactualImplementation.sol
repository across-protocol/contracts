// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CloneArgs } from "../periphery/counterfactual/CounterfactualCloneArgs.sol";

/**
 * @title ICounterfactualImplementation
 * @notice Interface for merkle leaf implementation contracts called by the CounterfactualDeposit dispatcher.
 * @dev Implementations are invoked via delegatecall from the clone, so `address(this)` is the clone address
 *      and `msg.sender` is the original caller. The dispatcher forwards `cloneArgs` after verifying its hash
 *      against the clone's immutable arg, so implementations can treat the struct as authoritative.
 */
interface ICounterfactualImplementation {
    /**
     * @notice Execute the implementation logic.
     * @param cloneArgs Dispatcher-verified identity fields (output token, destination, recipient, etc.).
     * @param params ABI-encoded route parameters committed to in the merkle leaf.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     */
    function execute(
        CloneArgs calldata cloneArgs,
        bytes calldata params,
        bytes calldata submitterData
    ) external payable;
}
