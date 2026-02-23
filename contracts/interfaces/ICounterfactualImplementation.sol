// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title ICounterfactualImplementation
 * @notice Interface for merkle leaf implementation contracts used by the CounterfactualDeposit dispatcher.
 * @dev Implementations are called via delegatecall from the clone, so `address(this)` is the clone address
 *      and `msg.sender` is the original caller.
 */
interface ICounterfactualImplementation {
    /**
     * @notice Execute the implementation logic.
     * @param params ABI-encoded route parameters committed to in the merkle leaf.
     * @param submitterData ABI-encoded data supplied by the caller at execution time.
     * @return Arbitrary return data from the implementation.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable returns (bytes memory);
}
