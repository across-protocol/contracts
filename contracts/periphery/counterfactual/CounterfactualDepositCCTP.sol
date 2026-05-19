// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CloneArgs } from "./CounterfactualCloneArgs.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery.
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to the merkle leaf. Layout invariant: first two fields are
 *         `(destinationChainId, outputToken)` for the dispatcher's standardized identity check.
 *         `outputToken` here is the destination-chain `finalToken` the user receives.
 */
struct CCTPDepositParams {
    uint256 destinationChainId;
    bytes32 outputToken;
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 burnToken;
    bytes32 destinationCaller;
    uint256 cctpMaxFeeBps;
    uint32 minFinalityThreshold;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    bytes actionData;
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time. `executionFee` is dynamic and
 *         authorized by `executionFeeSignature` (local signer). The CCTP periphery's own quote
 *         signature is supplied separately via `signature` and forwarded unchanged.
 */
struct CCTPSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    bytes32 nonce;
    uint256 cctpDeadline;
    uint256 executionFee;
    uint256 executionFeeDeadline;
    bytes signature;
    bytes executionFeeSignature;
}

/**
 * @title CounterfactualDepositCCTP
 * @notice Bridges tokens from a counterfactual clone via SponsoredCCTP.
 * @dev Called via delegatecall from the dispatcher. Two signatures are checked per execute:
 *      (1) the periphery quote signature (forwarded to the CCTP src periphery unchanged), and
 *      (2) the local EIP-712 signature authorizing the runtime `executionFee` (bounded by
 *      the leaf's `maxExecutionFee`).
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Emitted after a CCTP deposit is successfully executed.
    event CCTPDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        bytes32 nonce,
        uint256 cctpDeadline,
        uint256 executionFee
    );

    error InvalidExecutionFeeSignature();
    error ExecutionFeeSignatureExpired();
    error MaxExecutionFee();

    /// @notice EIP-712 typehash binding the local fee signature to (clone, leaf, runtime fee).
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256(
            "ExecuteCCTP(address clone,bytes32 paramsHash,uint256 amount,uint256 executionFee,uint256 executionFeeDeadline)"
        );

    /// @notice SponsoredCCTPSrcPeriphery contract.
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain.
    uint32 public immutable sourceDomain;

    /// @notice Local signer that authorizes the runtime `executionFee`.
    address public immutable signer;

    constructor(
        address _srcPeriphery,
        uint32 _sourceDomain,
        address _signer
    ) EIP712("CounterfactualDepositCCTP", "v1.0.0") {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev ERC-20 only (no native tokens). `finalRecipient` and `finalToken` for the CCTP quote
     *      come from `cloneArgs.recipient` / `cloneArgs.outputToken`.
     */
    function execute(
        CloneArgs calldata cloneArgs,
        bytes calldata params,
        bytes calldata submitterData
    ) external payable {
        CCTPDepositParams memory dp = abi.decode(params, (CCTPDepositParams));
        CCTPSubmitterData memory sd = abi.decode(submitterData, (CCTPSubmitterData));

        _verifyExecutionFeeSignature(keccak256(params), sd);

        if (sd.executionFee > dp.maxExecutionFee) revert MaxExecutionFee();

        address inputToken = address(uint160(uint256(dp.burnToken)));

        if (sd.executionFee > 0) IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(cloneArgs, dp, sd, depositAmount);

        emit CCTPDepositExecuted(sd.amount, sd.executionFeeRecipient, sd.nonce, sd.cctpDeadline, sd.executionFee);
    }

    function _verifyExecutionFeeSignature(bytes32 paramsHash, CCTPSubmitterData memory sd) private view {
        if (block.timestamp > sd.executionFeeDeadline) revert ExecutionFeeSignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_CCTP_TYPEHASH,
                address(this),
                paramsHash,
                sd.amount,
                sd.executionFee,
                sd.executionFeeDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.executionFeeSignature) != signer)
            revert InvalidExecutionFeeSignature();
    }

    function _depositForBurn(
        CloneArgs calldata cloneArgs,
        CCTPDepositParams memory dp,
        CCTPSubmitterData memory sd,
        uint256 depositAmount
    ) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: dp.destinationDomain,
                mintRecipient: dp.mintRecipient,
                amount: depositAmount,
                burnToken: dp.burnToken,
                destinationCaller: dp.destinationCaller,
                maxFee: (depositAmount * dp.cctpMaxFeeBps) / BPS_SCALAR,
                minFinalityThreshold: dp.minFinalityThreshold,
                nonce: sd.nonce,
                deadline: sd.cctpDeadline,
                maxBpsToSponsor: dp.maxBpsToSponsor,
                maxUserSlippageBps: dp.maxUserSlippageBps,
                finalRecipient: cloneArgs.recipient,
                finalToken: cloneArgs.outputToken,
                destinationDex: dp.destinationDex,
                accountCreationMode: dp.accountCreationMode,
                executionMode: dp.executionMode,
                actionData: dp.actionData
            }),
            sd.signature
        );
    }
}
