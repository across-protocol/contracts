// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice Runtime arguments for modular SpokePool execution.
struct SpokePoolExecutionRequest {
    uint256 inputAmount;
    uint256 outputAmount;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositModularSpokePoolModule
 * @notice Delegatecall module for SpokePool route execution.
 */
contract CounterfactualDepositModularSpokePoolModule is
    CounterfactualDepositSpokePoolModule,
    ICounterfactualDepositRouteModule
{
    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) CounterfactualDepositSpokePoolModule(_spokePool, _signer, _wrappedNativeToken) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata routeParams, bytes calldata executionParams) external payable {
        SpokePoolRoute memory route = abi.decode(routeParams, (SpokePoolRoute));
        (
            uint256 requestOffset,
            uint256 inputAmount,
            uint256 outputAmount,
            bytes32 exclusiveRelayer,
            uint32 exclusivityDeadline,
            address executionFeeRecipient,
            uint32 quoteTimestamp,
            uint32 fillDeadline,
            uint32 signatureDeadline,
            uint256 signatureOffset
        ) = abi.decode(
                executionParams,
                (uint256, uint256, uint256, bytes32, uint32, address, uint32, uint32, uint32, uint256)
            );

        _executeSpokePoolRoute(
            route,
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            executionFeeRecipient,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            _decodeTrailingBytes(executionParams, requestOffset + signatureOffset)
        );
    }

    /**
     * @dev Decodes a trailing bytes value from ABI-encoded calldata using its head offset.
     */
    function _decodeTrailingBytes(bytes calldata encoded, uint256 offset) internal pure returns (bytes calldata value) {
        uint256 length;
        assembly {
            length := calldataload(add(encoded.offset, offset))
        }
        return encoded[offset + 32:offset + 32 + length];
    }
}
