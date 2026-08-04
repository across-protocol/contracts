// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice Minimal interface for the canonical Multicall3 singleton.
 * @dev Only the subset used to make a neutral, failure-tolerant external call is declared here. The
 * canonical Multicall3 is deployed at 0xcA11bde05977b3631167028862bE2a173976CA11 on virtually all
 * EVM chains. See https://github.com/mds1/multicall.
 */
interface IMulticall3 {
    struct Call {
        address target;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function tryAggregate(bool requireSuccess, Call[] calldata calls) external payable returns (Result[] memory);
}
