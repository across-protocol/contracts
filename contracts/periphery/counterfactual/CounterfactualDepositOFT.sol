// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CloneArgs } from "./CounterfactualCloneArgs.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery.
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to the merkle leaf. Layout invariant: first two fields are
 *         `(destinationChainId, outputToken)` for the dispatcher's standardized identity check.
 *         `outputToken` here is the destination-chain `finalToken` the user receives.
 */
struct OFTDepositParams {
    uint256 destinationChainId;
    bytes32 outputToken;
    uint32 dstEid;
    bytes32 destinationHandler;
    address token;
    uint256 maxOftFeeBps;
    uint256 lzReceiveGasLimit;
    uint256 lzComposeGasLimit;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    address refundRecipient;
    bytes actionData;
    uint256 maxExecutionFee;
}

/**
 * @notice Data supplied by the submitter at execution time. `executionFee` is dynamic and authorized
 *         by `counterfactualSignature` (local signer). The OFT periphery's quote signature is
 *         supplied separately via `peripherySignature` and forwarded unchanged.
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
 * @notice Bridges tokens from a counterfactual clone via SponsoredOFT (LayerZero).
 * @dev Called via delegatecall from the dispatcher. `msg.value` is forwarded to the OFT periphery
 *      to cover LayerZero native messaging fees. Two signatures are checked per execute: the
 *      periphery quote signature (forwarded unchanged) and the local EIP-712 fee signature.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositOFT is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Emitted after an OFT deposit is successfully executed.
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

    /// @notice EIP-712 typehash binding the local fee signature to (clone, leaf, runtime fee).
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256(
            "ExecuteOFT(address clone,bytes32 paramsHash,uint256 amount,uint256 executionFee,uint32 signatureDeadline)"
        );

    /// @notice SponsoredOFTSrcPeriphery contract.
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain.
    uint32 public immutable srcEid;

    /// @notice Local signer that authorizes the runtime `executionFee`.
    address public immutable signer;

    constructor(
        address _oftSrcPeriphery,
        uint32 _srcEid,
        address _signer
    ) EIP712("CounterfactualDepositOFT", "v1.1.0") {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev ERC-20 only. `finalRecipient` and `finalToken` for the OFT quote come from
     *      `cloneArgs.recipient` / `cloneArgs.outputToken`. Forwards `msg.value` for LayerZero fees.
     */
    function execute(
        CloneArgs calldata cloneArgs,
        bytes calldata params,
        bytes calldata submitterData
    ) external payable {
        OFTDepositParams memory dp = abi.decode(params, (OFTDepositParams));
        OFTSubmitterData memory sd = abi.decode(submitterData, (OFTSubmitterData));

        _verifySignature(keccak256(params), sd);

        if (sd.executionFee > dp.maxExecutionFee) revert MaxExecutionFee();

        if (sd.executionFee > 0) IERC20(dp.token).safeTransfer(sd.executionFeeRecipient, sd.executionFee);

        uint256 depositAmount = sd.amount - sd.executionFee;

        IERC20(dp.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(cloneArgs, dp, sd, depositAmount);

        emit OFTDepositExecuted(sd.amount, sd.executionFeeRecipient, sd.nonce, sd.oftDeadline, sd.executionFee);
    }

    function _verifySignature(bytes32 paramsHash, OFTSubmitterData memory sd) private view {
        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_OFT_TYPEHASH,
                address(this),
                paramsHash,
                sd.amount,
                sd.executionFee,
                sd.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.counterfactualSignature) != signer)
            revert InvalidSignature();
    }

    function _deposit(
        CloneArgs calldata cloneArgs,
        OFTDepositParams memory dp,
        OFTSubmitterData memory sd,
        uint256 depositAmount
    ) private {
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: srcEid,
                    dstEid: dp.dstEid,
                    destinationHandler: dp.destinationHandler,
                    amountLD: depositAmount,
                    nonce: sd.nonce,
                    deadline: sd.oftDeadline,
                    maxBpsToSponsor: dp.maxBpsToSponsor,
                    maxUserSlippageBps: dp.maxUserSlippageBps,
                    finalRecipient: cloneArgs.recipient,
                    finalToken: cloneArgs.outputToken,
                    destinationDex: dp.destinationDex,
                    lzReceiveGasLimit: dp.lzReceiveGasLimit,
                    lzComposeGasLimit: dp.lzComposeGasLimit,
                    maxOftFeeBps: dp.maxOftFeeBps,
                    accountCreationMode: dp.accountCreationMode,
                    executionMode: dp.executionMode,
                    actionData: dp.actionData
                }),
                unsignedParams: SponsoredOFTInterface.UnsignedQuoteParams({ refundRecipient: dp.refundRecipient })
            }),
            sd.peripherySignature
        );
    }
}
