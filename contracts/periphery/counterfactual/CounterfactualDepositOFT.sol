// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CloneIdentity } from "./CloneIdentity.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery.
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters committed to the merkle leaf. The dispatcher's leaf is agnostic to
 *         clone identity, so this impl binds the leaf to a specific clone by committing
 *         `outputToken` and `destinationChainId` inside `routeParams`. `execute` verifies these
 *         match the dispatcher-forwarded `cloneArgs` values via `CloneIdentity.enforce(...)`.
 *         The destination chain's LayerZero endpoint ID lives in `dstEid`.
 */
struct OFTRouteParams {
    bytes32 outputToken;
    uint256 destinationChainId;
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

    /// @notice EIP-712 typehash binding the local fee signature to (nonce, runtime fee, deadline).
    /// @dev The clone is bound implicitly via the EIP-712 domain separator's `verifyingContract`
    ///      field (= `address(this)` = the clone during delegatecall). `amount` is bound implicitly
    ///      via the periphery signature, which covers `depositAmount = sd.amount - sd.executionFee`.
    ///      The route is bound transitively: the periphery signature commits `(route, nonce)`
    ///      together, so binding the local sig to `nonce` pins the route via the periphery's quote
    ///      (and cleanly gives single-use replay protection — once the periphery consumes the
    ///      nonce, the local sig can never be replayed).
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

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
    ) EIP712("CounterfactualDepositOFT", "v2.0.0") {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev ERC-20 only. `finalRecipient` and `finalToken` for the OFT quote come from the
     *      dispatcher-verified `recipient` / `outputToken`. OFT routing uses `routeParams.dstEid`
     *      (LayerZero-specific) for periphery dispatch; the EVM `destinationChainId` is committed
     *      inside `routeParams` purely as identity binding against the clone. `userAddress` is
     *      unused (policy-callable impl). Forwards `msg.value` for LayerZero fees.
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address /* userAddress */,
        bytes calldata routeParamsEncoded,
        bytes calldata submitterDataEncoded
    ) external payable {
        OFTRouteParams memory routeParams = abi.decode(routeParamsEncoded, (OFTRouteParams));
        OFTSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (OFTSubmitterData));

        // Bind the leaf to this clone's identity. The leaf already commits `keccak256(routeParams)`,
        // so the values inside `routeParams` are authenticated by the merkle proof; this check
        // verifies they match the dispatcher-forwarded `cloneArgs` values.
        CloneIdentity.enforce(routeParams.outputToken, outputToken, routeParams.destinationChainId, destinationChainId);

        _verifySignature(submitterData);

        if (submitterData.executionFee > routeParams.maxExecutionFee) revert MaxExecutionFee();

        if (submitterData.executionFee > 0)
            IERC20(routeParams.token).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;

        IERC20(routeParams.token).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(recipient, outputToken, routeParams, submitterData, depositAmount);

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

    function _deposit(
        bytes32 recipient,
        bytes32 outputToken,
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
                    finalRecipient: recipient,
                    finalToken: outputToken,
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
