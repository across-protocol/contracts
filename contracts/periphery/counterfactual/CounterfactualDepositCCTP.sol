// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";
import { CloneIdentity } from "./CloneIdentity.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery.
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to the merkle leaf. The dispatcher's leaf is agnostic to
 *         clone identity, so this impl binds the leaf to a specific clone by committing
 *         `outputToken` and `destinationChainId` inside `routeParams`. `execute` verifies these
 *         match the dispatcher-forwarded `cloneArgs` values via `CloneIdentity.enforce(...)`.
 *         The destination chain's CCTP-specific identifier lives in `destinationDomain`.
 */
struct CCTPRouteParams {
    bytes32 outputToken;
    uint256 destinationChainId;
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
 *         authorized by `counterfactualSignature` (local signer). The CCTP periphery's own quote
 *         signature is supplied separately via `peripherySignature` and forwarded unchanged.
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
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTP(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

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
    ) EIP712("CounterfactualDepositCCTP", "v2.0.0") {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev ERC-20 only (no native tokens). `finalRecipient` and `finalToken` for the CCTP quote
     *      come from the dispatcher-verified `recipient` / `outputToken`. CCTP routing uses
     *      `routeParams.destinationDomain` (CCTP-specific) for periphery dispatch; the EVM
     *      `destinationChainId` is committed inside `routeParams` purely as identity binding
     *      against the clone. `userAddress` is unused (policy-callable impl).
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address /* userAddress */,
        bytes calldata routeParamsEncoded,
        bytes calldata submitterDataEncoded
    ) external payable {
        CCTPRouteParams memory routeParams = abi.decode(routeParamsEncoded, (CCTPRouteParams));
        CCTPSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (CCTPSubmitterData));

        // Bind the leaf to this clone's identity. The leaf already commits `keccak256(routeParams)`,
        // so the values inside `routeParams` are authenticated by the merkle proof; this check
        // verifies they match the dispatcher-forwarded `cloneArgs` values.
        CloneIdentity.enforce(routeParams.outputToken, outputToken, routeParams.destinationChainId, destinationChainId);

        _verifySignature(submitterData);

        if (submitterData.executionFee > routeParams.maxExecutionFee) revert MaxExecutionFee();

        address inputToken = address(uint160(uint256(routeParams.burnToken)));

        if (submitterData.executionFee > 0)
            IERC20(inputToken).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(recipient, outputToken, routeParams, submitterData, depositAmount);

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

    function _depositForBurn(
        bytes32 recipient,
        bytes32 outputToken,
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
                finalRecipient: recipient,
                finalToken: outputToken,
                destinationDex: routeParams.destinationDex,
                accountCreationMode: routeParams.accountCreationMode,
                executionMode: routeParams.executionMode,
                actionData: routeParams.actionData
            }),
            submitterData.peripherySignature
        );
    }
}
