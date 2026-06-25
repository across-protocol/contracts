// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface V5SpokePoolInterface {
    /// @notice Thrown when a V5 deposit or fill is attempted outside of a V5 entrypoint / live Gateway execution.
    error V5RequiresGateway();
    /// @notice Thrown when a slow fill is attempted against a V5 deposit (V5 deposits are Gateway-fill-only).
    error V5SlowFillNotAllowed();
    /// @notice
    error V5OutputAmountTooLow();

    struct InputParamsV5 {
        bytes32 recipient;
        bytes32 outputToken;
        uint256 minOutputAmount;
    }

    struct JitInputParamsV5 {
        bytes32 depositor;
        bytes32 exclusiveRelayer;
        bytes32 inputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        uint256 repaymentChainId;
        bytes32 repaymentAddress;
    }
}
