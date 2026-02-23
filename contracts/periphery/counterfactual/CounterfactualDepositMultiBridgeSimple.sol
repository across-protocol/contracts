// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositCCTPModule, CCTPRoute } from "./CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFTModule, OFTRoute } from "./CounterfactualDepositOFT.sol";
import { CounterfactualDepositSpokePoolModule, SpokePoolRoute } from "./CounterfactualDepositSpokePool.sol";

/**
 * @notice Simple hash-committed config for a multi-bridge counterfactual address.
 * @dev `commonParamsHash` is an optional application-level commitment.
 *      Each route hash enables/disables a bridge:
 *      - hash == 0: route disabled
 *      - hash != 0: route enabled and must match keccak256(route params) at execution.
 */
struct CounterfactualDepositSimpleConfig {
    bytes32 commonParamsHash;
    bytes32 cctpRouteHash;
    bytes32 oftRouteHash;
    bytes32 spokePoolRouteHash;
    address userWithdrawAddress;
    address adminWithdrawAddress;
}

/**
 * @title CounterfactualDepositMultiBridgeSimple
 * @notice Unified counterfactual implementation with direct per-route hash commitments (no merkle proofs).
 * @dev Clone immutables commit to `keccak256(abi.encode(CounterfactualDepositSimpleConfig))`.
 */
contract CounterfactualDepositMultiBridgeSimple is
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
     * @notice Executes a CCTP route if enabled and hash-matched.
     */
    function executeCCTP(
        CounterfactualDepositSimpleConfig memory config,
        CCTPRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(config))) {
        _verifyRouteHash(config.cctpRouteHash, _cctpRouteHash(route));
        _executeCCTPRoute(route, amount, executionFeeRecipient, nonce, cctpDeadline, signature);
    }

    /**
     * @notice Executes an OFT route if enabled and hash-matched.
     */
    function executeOFT(
        CounterfactualDepositSimpleConfig memory config,
        OFTRoute memory route,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) external payable verifyParamsHash(keccak256(abi.encode(config))) {
        _verifyRouteHash(config.oftRouteHash, _oftRouteHash(route));
        _executeOFTRoute(route, amount, executionFeeRecipient, nonce, oftDeadline, signature);
    }

    /**
     * @notice Executes a SpokePool route if enabled and hash-matched.
     */
    function executeSpokePool(
        CounterfactualDepositSimpleConfig memory config,
        SpokePoolRoute memory route,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(config))) {
        _verifyRouteHash(config.spokePoolRouteHash, _spokePoolRouteHash(route));
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

    /**
     * @dev Extracts user withdraw address from simple config bytes.
     */
    function _getUserWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (CounterfactualDepositSimpleConfig)).userWithdrawAddress;
    }

    /**
     * @dev Extracts admin withdraw address from simple config bytes.
     */
    function _getAdminWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (CounterfactualDepositSimpleConfig)).adminWithdrawAddress;
    }

    /**
     * @dev Checks route enablement and exact hash match.
     */
    function _verifyRouteHash(bytes32 committedRouteHash, bytes32 routeHash) internal pure {
        if (committedRouteHash == bytes32(0)) revert RouteDisabled();
        if (committedRouteHash != routeHash) revert InvalidRouteHash();
    }
}
