// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 */
struct OFTRouteParams {
    uint256 sourceChainId;
    uint32 dstEid;
    bytes32 destinationHandler;
    address token;
    uint256 maxOftFeeBps;
    uint256 lzReceiveGasLimit;
    uint256 lzComposeGasLimit;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    address refundRecipient;
    bytes actionData;
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct OFTSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 oftDeadline;
    uint256 executionFee;
    uint32 signatureDeadline;
    bytes peripherySignature;
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher.
 *      msg.value covers LayerZero native messaging fees.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositOFT is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after an OFT deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param nonce OFT nonce used for the deposit.
     * @param oftDeadline Deadline timestamp for the OFT quote.
     * @param executionFee Execution fee paid to the executor (in input token).
     */
    event OFTDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        uint256 executionFee
    );

    error InvalidSignature();
    error SignatureExpired();
    error MaxExecutionFee();
    error SourceChainMismatch();

    /// @notice EIP-712 typehash binding the local fee signature to (nonce, runtime fee, deadline).
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    /// @notice Signer that authorizes the runtime execution fee.
    address public immutable signer;

    constructor(
        address _oftSrcPeriphery,
        uint32 _srcEid,
        address _signer
    ) EIP712("CounterfactualDepositOFT", "v2.0.0") {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `routeParamsEncoded` is ABI-encoded as `OFTRouteParams`;
     *      `submitterDataEncoded` as `OFTSubmitterData` (includes a signature forwarded to the OFT periphery).
     *      ERC-20 only. Forwards `msg.value` for LayerZero messaging fees. No local signature verification.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        OFTRouteParams memory routeParams = abi.decode(routeParamsEncoded, (OFTRouteParams));
        OFTSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (OFTSubmitterData));

        if (block.chainid != routeParams.sourceChainId) revert SourceChainMismatch();
        _verifySignature(submitterData);
        if (submitterData.executionFee > routeParams.maxExecutionFee) revert MaxExecutionFee();

        // The fee is paid BEFORE the periphery call, and this ordering is load-bearing: the local
        // signature binds only `(nonce, executionFee, signatureDeadline)`, so replay protection for the
        // (route, amount) tuple comes from the periphery's nonce-uniqueness check. A replayed fee
        // signature reverts at `deposit`, atomically rolling back this fee transfer.
        if (submitterData.executionFee > 0)
            IERC20(routeParams.token).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;

        IERC20(routeParams.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(routeParams, submitterData, depositAmount);

        emit OFTDepositExecuted(
            submitterData.amount,
            submitterData.executionFeeRecipient,
            submitterData.nonce,
            submitterData.oftDeadline,
            submitterData.executionFee
        );
    }

    function _verifySignature(OFTSubmitterData memory submitterData) private view {
        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_OFT_TYPEHASH,
                submitterData.nonce,
                submitterData.executionFee,
                submitterData.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != signer)
            revert InvalidSignature();
    }

    /**
     * @notice Calls deposit on the SponsoredOFTSrcPeriphery with the constructed quote.
     * @param routeParams Route parameters from the merkle leaf.
     * @param submitterData Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _deposit(
        OFTRouteParams memory routeParams,
        OFTSubmitterData memory submitterData,
        uint256 depositAmount
    ) private {
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: srcEid,
                    dstEid: routeParams.dstEid,
                    destinationHandler: routeParams.destinationHandler,
                    amountLD: depositAmount,
                    nonce: submitterData.nonce,
                    deadline: submitterData.oftDeadline,
                    maxBpsToSponsor: routeParams.maxBpsToSponsor,
                    maxUserSlippageBps: routeParams.maxUserSlippageBps,
                    finalRecipient: routeParams.finalRecipient,
                    finalToken: routeParams.finalToken,
                    destinationDex: routeParams.destinationDex,
                    lzReceiveGasLimit: routeParams.lzReceiveGasLimit,
                    lzComposeGasLimit: routeParams.lzComposeGasLimit,
                    maxOftFeeBps: routeParams.maxOftFeeBps,
                    accountCreationMode: routeParams.accountCreationMode,
                    executionMode: routeParams.executionMode,
                    actionData: routeParams.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({
                    refundRecipient: routeParams.refundRecipient
                })
            }),
            submitterData.peripherySignature
        );
    }
}
