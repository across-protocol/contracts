// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface V5SpokePoolInterface {
    struct InputParamsV5 {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
    }

    struct JitInputParamsV5 {
        bytes32 exclusiveRelayer;
        uint256 outputAmount;
        uint32 exclusivityDeadline;
        uint256 repaymentChainId;
        bytes32 repaymentAddress;
    }
}
