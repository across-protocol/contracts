// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 */
struct CCTPRouteParams {
    uint256 sourceChainId;
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 burnToken;
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint32 minFinalityThreshold;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    bytes actionData;
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct CCTPSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    uint256 executionFee;
    uint32 signatureDeadline;
    bytes peripherySignature;
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce CCTP nonce used for the deposit.
     * @param cctpDeadline Deadline timestamp for the CCTP quote.
     * @param executionFee Execution fee paid to the executor (in input token).
     */
    event CCTPDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        uint256 executionFee
    );

    error InvalidSignature();
    error SignatureExpired();
    error MaxExecutionFee();
    error SourceChainMismatch();

    /// @notice EIP-712 typehash binding the local fee signature to (nonce, runtime fee, deadline).
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTP(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /// @notice Signer that authorizes the runtime execution fee.
    address public immutable signer;

    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain,
        address _signer
    ) EIP712("CounterfactualDepositCCTP", "v2.0.0") {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `routeParamsEncoded` is ABI-encoded as `CCTPRouteParams`;
     *      `submitterDataEncoded` as `CCTPSubmitterData` (includes a signature forwarded to the CCTP periphery).
     *      ERC-20 only (no native tokens). No local signature verification — delegated to `srcPeriphery`.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        CCTPRouteParams memory routeParams = abi.decode(routeParamsEncoded, (CCTPRouteParams));
        CCTPSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (CCTPSubmitterData));

        if (block.chainid != routeParams.sourceChainId) revert SourceChainMismatch();
        _verifySignature(submitterData);
        if (submitterData.executionFee > routeParams.maxExecutionFee) revert MaxExecutionFee();

        address inputToken = address(uint160(uint256(routeParams.burnToken)));

        // The fee is paid BEFORE the periphery call, and this ordering is load-bearing: the local
        // signature binds only `(nonce, executionFee, signatureDeadline)`, so replay protection for the
        // (route, amount) tuple comes from the periphery's nonce-uniqueness check. A replayed fee
        // signature reverts at `depositForBurn`, atomically rolling back this fee transfer.
        if (submitterData.executionFee > 0)
            IERC20(inputToken).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(routeParams, submitterData, depositAmount);

        emit CCTPDepositExecuted(
            submitterData.amount,
            submitterData.executionFeeRecipient,
            submitterData.nonce,
            submitterData.cctpDeadline,
            submitterData.executionFee
        );
    }

    function _verifySignature(CCTPSubmitterData memory submitterData) private view {
        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_CCTP_TYPEHASH,
                submitterData.nonce,
                submitterData.executionFee,
                submitterData.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != signer)
            revert InvalidSignature();
    }

    /**
     * @notice Calls depositForBurn on the SponsoredCCTPSrcPeriphery with the constructed quote.
     * @param routeParams Route parameters from the merkle leaf.
     * @param submitterData Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _depositForBurn(
        CCTPRouteParams memory routeParams,
        CCTPSubmitterData memory submitterData,
        uint256 depositAmount
    ) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: routeParams.destinationDomain,
                mintRecipient: routeParams.mintRecipient,
                amount: depositAmount,
                burnToken: routeParams.burnToken,
                destinationCaller: routeParams.destinationCaller,
                maxFee: (depositAmount * routeParams.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: routeParams.minFinalityThreshold,
                nonce: submitterData.nonce,
                deadline: submitterData.cctpDeadline,
                maxBpsToSponsor: routeParams.maxBpsToSponsor,
                maxUserSlippageBps: routeParams.maxUserSlippageBps,
                finalRecipient: routeParams.finalRecipient,
                finalToken: routeParams.finalToken,
                destinationDex: routeParams.destinationDex,
                accountCreationMode: routeParams.accountCreationMode,
                executionMode: routeParams.executionMode,
                actionData: routeParams.actionData
            }),
            submitterData.peripherySignature
        );
    }
}
