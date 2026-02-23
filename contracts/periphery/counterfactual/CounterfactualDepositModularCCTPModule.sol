// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositCCTPModule, CCTPRoute } from "./CounterfactualDepositCCTP.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice Runtime arguments for modular CCTP execution.
struct CCTPExecutionRequest {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositModularCCTPModule
 * @notice Delegatecall module for CCTP route execution.
 */
contract CounterfactualDepositModularCCTPModule is CounterfactualDepositCCTPModule, ICounterfactualDepositRouteModule {
    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain
    ) CounterfactualDepositCCTPModule(_srcPeriphery, _sourceDomain) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata routeParams, bytes calldata executionParams) external payable {
        CCTPRoute memory route = abi.decode(routeParams, (CCTPRoute));
        (
            uint256 requestOffset,
            uint256 amount,
            address executionFeeRecipient,
            bytes32 nonce,
            uint256 cctpDeadline,
            uint256 signatureOffset
        ) = abi.decode(executionParams, (uint256, uint256, address, bytes32, uint256, uint256));
        _executeCCTPRoute(
            route,
            amount,
            executionFeeRecipient,
            nonce,
            cctpDeadline,
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
