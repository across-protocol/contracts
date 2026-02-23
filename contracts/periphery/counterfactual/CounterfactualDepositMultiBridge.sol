// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositGlobalConfig } from "./CounterfactualDepositBase.sol";
import { CounterfactualDepositCCTPModule, CCTPRoute } from "./CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFTModule, OFTRoute } from "./CounterfactualDepositOFT.sol";
import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";

/// @notice Bridge families supported by this unified implementation.
enum BridgeType {
    CCTP,
    OFT,
    SPOKE_POOL
}

/**
 * @title CounterfactualDepositMultiBridge
 * @notice Unified counterfactual deposit implementation that supports CCTP, OFT, and SpokePool routes.
 * @dev Clone immutables commit to `keccak256(abi.encode(CounterfactualDepositGlobalConfig))`.
 *      The global config commits withdraw recipients and a merkle root of all allowed bridge routes.
 */
contract CounterfactualDepositMultiBridge is
    CounterfactualDepositCCTPModule,
    CounterfactualDepositOFTModule,
    CounterfactualDepositSpokePoolModule
{
    /**
     * @param _srcPeriphery SponsoredCCTPSrcPeriphery address.
     * @param _sourceDomain CCTP source domain.
     * @param _oftSrcPeriphery SponsoredOFTSrcPeriphery address.
     * @param _srcEid OFT source endpoint id.
     * @param _spokePool SpokePool address.
     * @param _signer SpokePool quote signer.
     * @param _wrappedNativeToken Wrapped native token used for native SpokePool deposits.
     */
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

    /**
     * @notice Computes CCTP route leaf hash for merkle proofs.
     */
    function computeCCTPRouteLeaf(CCTPRoute memory route) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(BridgeType.CCTP), _cctpRouteHash(route)));
    }

    /**
     * @notice Computes OFT route leaf hash for merkle proofs.
     */
    function computeOFTRouteLeaf(OFTRoute memory route) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(BridgeType.OFT), _oftRouteHash(route)));
    }

    /**
     * @notice Computes SpokePool route leaf hash for merkle proofs.
     */
    function computeSpokePoolRouteLeaf(SpokePoolRoute memory route) public pure returns (bytes32) {
        return keccak256(abi.encode(uint8(BridgeType.SPOKE_POOL), _spokePoolRouteHash(route)));
    }

    /**
     * @notice Executes a CCTP route if it is authorized by the clone's routes merkle root.
     */
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
        _verifyRoute(globalConfig, computeCCTPRouteLeaf(route), proof);
        _executeCCTPRoute(route, amount, executionFeeRecipient, nonce, cctpDeadline, signature);
    }

    /**
     * @notice Executes an OFT route if it is authorized by the clone's routes merkle root.
     */
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
        _verifyRoute(globalConfig, computeOFTRouteLeaf(route), proof);
        _executeOFTRoute(route, amount, executionFeeRecipient, nonce, oftDeadline, signature);
    }

    /**
     * @notice Executes a SpokePool route if it is authorized by the clone's routes merkle root.
     */
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
        _verifyRoute(globalConfig, computeSpokePoolRouteLeaf(route), proof);
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
