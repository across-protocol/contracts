// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualImplementationBase } from "./CounterfactualImplementationBase.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery, plus reading its
 *         immutable `TOKEN`.
 * @custom:security-contact bugs@across.to
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;

    /// @notice The single ERC-20 this periphery deposits — `safeTransferFrom`-pulled from `msg.sender`.
    function TOKEN() external view returns (address);
}

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev Chain-agnostic: it names no source chain and no token address. The source EID and periphery come
 *      from `beacon.oftSrcEid()` / `beacon.oftSrcPeriphery()`, and the input token is resolved at runtime
 *      from the periphery's immutable `TOKEN` — so the leaf works for any token the chain's periphery is
 *      deployed for (USDC, USDT0, …) without baking the token into the merkle commitment.
 */
struct OFTRouteParams {
    uint32 dstEid;
    bytes32 destinationHandler;
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
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. The periphery, source EID and
 *      fee signer are resolved from the `CounterfactualBeacon` at runtime; the input token is resolved
 *      from the periphery's immutable `TOKEN` (so the impl is token-agnostic and works with USDT0/USDC/etc.
 *      peripheries equally). This implementation holds no chain-specific values and has one address on
 *      every chain — a single leaf works everywhere (see `CounterfactualImplementationBase`). `msg.value`
 *      covers LayerZero native messaging fees.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositOFT is CounterfactualImplementationBase, EIP712 {
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

    /// @notice EIP-712 typehash binding the local fee signature to (nonce, runtime fee, deadline).
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    constructor() EIP712("CounterfactualDepositOFT", "v2.0.0") {}

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `routeParamsEncoded` is ABI-encoded as `OFTRouteParams`;
     *      `submitterDataEncoded` as `OFTSubmitterData` (includes a signature forwarded to the OFT periphery).
     *      ERC-20 only — the token is the periphery's immutable `TOKEN`. Forwards `msg.value` for LayerZero
     *      messaging fees. No local route verification.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        OFTRouteParams memory routeParams = abi.decode(routeParamsEncoded, (OFTRouteParams));
        OFTSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (OFTSubmitterData));

        _verifySignature(submitterData);
        if (submitterData.executionFee > routeParams.maxExecutionFee) revert MaxExecutionFee();

        address oftSrcPeriphery = _requireConfigured(_beacon().oftSrcPeriphery());
        // Pull the input token from the periphery's immutable `TOKEN` so the leaf works for whichever
        // ERC-20 the chain's periphery was deployed for (USDC, USDT0, etc.). The periphery enforces
        // non-zero `_token` at construction, so we don't re-check here.
        address inputToken = ISponsoredOFTSrcPeriphery(oftSrcPeriphery).TOKEN();

        // The fee is paid BEFORE the periphery call, and this ordering is load-bearing: the local
        // signature binds only `(nonce, executionFee, signatureDeadline)`, so replay protection for the
        // (route, amount) tuple comes from the periphery's nonce-uniqueness check. A replayed fee
        // signature reverts at `deposit`, atomically rolling back this fee transfer.
        if (submitterData.executionFee > 0)
            IERC20(inputToken).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;

        IERC20(inputToken).forceApprove(oftSrcPeriphery, depositAmount);

        _deposit(oftSrcPeriphery, routeParams, submitterData, depositAmount);

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
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != _beacon().signer())
            revert InvalidSignature();
    }

    /**
     * @notice Calls deposit on the SponsoredOFTSrcPeriphery with the constructed quote.
     * @param oftSrcPeriphery The sponsored OFT source periphery (resolved from the beacon).
     * @param routeParams Route parameters from the merkle leaf.
     * @param submitterData Submitter-provided execution data.
     * @param depositAmount Amount to deposit after deducting the execution fee.
     */
    function _deposit(
        address oftSrcPeriphery,
        OFTRouteParams memory routeParams,
        OFTSubmitterData memory submitterData,
        uint256 depositAmount
    ) private {
        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(
            SponsoredOFTInterface.Quote({
                signedParams: SponsoredOFTInterface.SignedQuoteParams({
                    srcEid: _beacon().oftSrcEid(),
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
