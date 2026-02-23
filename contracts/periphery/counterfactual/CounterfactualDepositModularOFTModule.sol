// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositOFTModule, OFTRoute } from "./CounterfactualDepositOFT.sol";
import { ICounterfactualDepositRouteModule } from "../../interfaces/ICounterfactualDepositRouteModule.sol";

/// @notice Runtime arguments for modular OFT execution.
struct OFTExecutionRequest {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositModularOFTModule
 * @notice Delegatecall module for OFT route execution.
 */
contract CounterfactualDepositModularOFTModule is CounterfactualDepositOFTModule, ICounterfactualDepositRouteModule {
    constructor(address _oftSrcPeriphery, uint32 _srcEid) CounterfactualDepositOFTModule(_oftSrcPeriphery, _srcEid) {}

    /**
     * @inheritdoc ICounterfactualDepositRouteModule
     */
    function execute(bytes calldata routeParams, bytes calldata executionParams) external payable {
        OFTRoute memory route = abi.decode(routeParams, (OFTRoute));
        (
            uint256 requestOffset,
            uint256 amount,
            address executionFeeRecipient,
            bytes32 nonce,
            uint256 oftDeadline,
            uint256 signatureOffset
        ) = abi.decode(executionParams, (uint256, uint256, address, bytes32, uint256, uint256));
        _executeOFTRoute(
            route,
            amount,
            executionFeeRecipient,
            nonce,
            oftDeadline,
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
