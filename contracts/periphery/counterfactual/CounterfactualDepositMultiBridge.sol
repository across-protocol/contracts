// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositGlobalConfig } from "./CounterfactualDepositBase.sol";
import { CounterfactualDepositCCTPModule, CCTPRoute } from "./CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFTModule, OFTRoute } from "./CounterfactualDepositOFT.sol";
import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";

contract CounterfactualDepositMultiBridge is
    CounterfactualDepositCCTPModule,
    CounterfactualDepositOFTModule,
    CounterfactualDepositSpokePoolModule
{
    uint8 internal constant BRIDGE_TYPE_CCTP = 0;
    uint8 internal constant BRIDGE_TYPE_OFT = 1;
    uint8 internal constant BRIDGE_TYPE_SPOKE_POOL = 2;

    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain,
        address _oftSrcPeriphery,
        uint32 _srcEid,
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    )
        CounterfactualDepositCCTPModule(_srcPeriphery, _sourceDomain)
        CounterfactualDepositOFTModule(_oftSrcPeriphery, _srcEid)
        CounterfactualDepositSpokePoolModule(_spokePool, _signer, _wrappedNativeToken)
    {}

    receive() external payable {}

    function computeCCTPRouteLeaf(bytes32 sharedParamsHash, CCTPRoute memory route) public pure returns (bytes32) {
        return keccak256(abi.encode(BRIDGE_TYPE_CCTP, sharedParamsHash, _cctpRouteHash(route)));
    }

    function computeOFTRouteLeaf(bytes32 sharedParamsHash, OFTRoute memory route) public pure returns (bytes32) {
        return keccak256(abi.encode(BRIDGE_TYPE_OFT, sharedParamsHash, _oftRouteHash(route)));
    }

    function computeSpokePoolRouteLeaf(
        bytes32 sharedParamsHash,
        SpokePoolRoute memory route
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(BRIDGE_TYPE_SPOKE_POOL, sharedParamsHash, _spokePoolRouteHash(route)));
    }

    function executeCCTP(
        CounterfactualDepositGlobalConfig memory globalConfig,
        CCTPRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature,
        bytes32[] calldata proof
    ) external verifyParamsHash(keccak256(abi.encode(globalConfig))) {
        _verifyRoute(globalConfig, computeCCTPRouteLeaf(globalConfig.sharedParamsHash, route), proof);
        _executeCCTPRoute(route, amount, executionFeeRecipient, nonce, cctpDeadline, signature);
    }

    function executeOFT(
        CounterfactualDepositGlobalConfig memory globalConfig,
        OFTRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature,
        bytes32[] calldata proof
    ) external payable verifyParamsHash(keccak256(abi.encode(globalConfig))) {
        _verifyRoute(globalConfig, computeOFTRouteLeaf(globalConfig.sharedParamsHash, route), proof);
        _executeOFTRoute(route, amount, executionFeeRecipient, nonce, oftDeadline, signature);
    }

    function executeSpokePool(
        CounterfactualDepositGlobalConfig memory globalConfig,
        SpokePoolRoute memory route,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature,
        bytes32[] calldata proof
    ) external verifyParamsHash(keccak256(abi.encode(globalConfig))) {
        _verifyRoute(globalConfig, computeSpokePoolRouteLeaf(globalConfig.sharedParamsHash, route), proof);
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
            signature
        );
    }
}
