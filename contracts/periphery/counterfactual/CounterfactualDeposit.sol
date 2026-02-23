// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePool, SpokePoolImmutables } from "./CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositCCTP, CCTPDepositParams } from "./CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFT, OFTDepositParams } from "./CounterfactualDepositOFT.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Unified parameters for a counterfactual deposit clone supporting all bridging methods.
 * @dev The stored paramsHash is keccak256(abi.encode(CounterfactualDepositParams)). Route sub-hashes
 *      allow enabling/disabling specific bridging methods (bytes32(0) = disabled).
 */
struct CounterfactualDepositParams {
    address userWithdrawAddress;
    address adminWithdrawAddress;
    uint256 executionFee;
    bytes32 spokePoolRouteHash; // keccak256(abi.encode(SpokePoolImmutables)) or bytes32(0)
    bytes32 cctpRouteHash; // keccak256(abi.encode(CCTPDepositParams)) or bytes32(0)
    bytes32 oftRouteHash; // keccak256(abi.encode(OFTDepositParams)) or bytes32(0)
}

/**
 * @title CounterfactualDeposit
 * @notice Unified implementation supporting SpokePool, CCTP, and OFT bridging from a single clone address.
 * @dev Inherits all three bridging implementations. The clone stores a hash of CounterfactualDepositParams
 *      which includes sub-hashes for each enabled route. The signer chooses the bridging method at execution
 *      time while the counterfactual address remains the same.
 */
contract CounterfactualDeposit is CounterfactualDepositSpokePool, CounterfactualDepositCCTP, CounterfactualDepositOFT {
    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken,
        address _cctpSrcPeriphery,
        uint32 _cctpSourceDomain,
        address _oftSrcPeriphery,
        uint32 _oftSrcEid
    )
        CounterfactualDepositSpokePool(_spokePool, _signer, _wrappedNativeToken)
        CounterfactualDepositCCTP(_cctpSrcPeriphery, _cctpSourceDomain)
        CounterfactualDepositOFT(_oftSrcPeriphery, _oftSrcEid)
    {}

    // ─── Unified entry points ─────────────────────────────────────────

    function executeSpokePoolDeposit(
        CounterfactualDepositParams memory params,
        SpokePoolImmutables memory routeParams,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(params))) {
        if (params.spokePoolRouteHash == bytes32(0)) revert RouteDisabled();
        if (keccak256(abi.encode(routeParams)) != params.spokePoolRouteHash) revert InvalidRouteHash();
        _executeSpokePoolDeposit(
            routeParams,
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            executionFeeRecipient,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            signature,
            params.executionFee
        );
    }

    function executeCCTPDeposit(
        CounterfactualDepositParams memory params,
        CCTPDepositParams memory routeParams,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(params))) {
        if (params.cctpRouteHash == bytes32(0)) revert RouteDisabled();
        if (keccak256(abi.encode(routeParams)) != params.cctpRouteHash) revert InvalidRouteHash();
        _executeCCTPDeposit(
            routeParams,
            amount,
            executionFeeRecipient,
            nonce,
            cctpDeadline,
            signature,
            params.executionFee
        );
    }

    function executeOFTDeposit(
        CounterfactualDepositParams memory params,
        OFTDepositParams memory routeParams,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) external payable verifyParamsHash(keccak256(abi.encode(params))) {
        if (params.oftRouteHash == bytes32(0)) revert RouteDisabled();
        if (keccak256(abi.encode(routeParams)) != params.oftRouteHash) revert InvalidRouteHash();
        _executeOFTDeposit(
            routeParams,
            amount,
            executionFeeRecipient,
            nonce,
            oftDeadline,
            signature,
            params.executionFee
        );
    }

    // ─── Withdraw address resolution (unified params) ─────────────────

    /// @inheritdoc CounterfactualDepositBase
    function _getUserWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (CounterfactualDepositParams)).userWithdrawAddress;
    }

    /// @inheritdoc CounterfactualDepositBase
    function _getAdminWithdrawAddress(bytes calldata params) internal pure override returns (address) {
        return abi.decode(params, (CounterfactualDepositParams)).adminWithdrawAddress;
    }
}
