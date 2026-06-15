// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredOFTInterface } from "../../interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualImplementationBase } from "./CounterfactualImplementationBase.sol";

/// @notice Minimal interface for SponsoredOFTSrcPeriphery: `deposit` plus its immutable `TOKEN`.
interface ISponsoredOFTSrcPeriphery {
    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata signature) external payable;

    /// @notice The single ERC-20 this periphery deposits (pulled from `msg.sender`).
    function TOKEN() external view returns (address);
}

/**
 * @notice Route parameters committed to in the merkle leaf (chain-agnostic: no source chain, no token).
 * @dev `peripheryGetter` is the selector of the beacon getter for the SponsoredOFTSrcPeriphery to use
 *      (e.g. `beacon.oftSrcPeriphery.selector`). Each OFT periphery is single-token (immutable `TOKEN`), so
 *      naming the periphery selects the input token — supporting many OFT tokens with one leaf shape. The
 *      source EID comes from `beacon.oftSrcEid()`.
 */
struct OFTRouteParams {
    bytes4 peripheryGetter;
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
    /// @dev Selector of the beacon getter for this route's per-chain execution-fee cap (e.g.
    ///      `beacon.usdtOftMaxExecutionFee.selector`).
    bytes4 maxExecutionFeeGetter;
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
 * @notice Counterfactual deposit via SponsoredOFT (LayerZero).
 * @dev Delegatecalled by the dispatcher. Source EID and fee signer come from the beacon; the periphery from
 *      the beacon getter the leaf's `peripheryGetter` names, and the input token from that periphery's
 *      immutable `TOKEN` — so the impl is token-agnostic, holds no chain-specific values, and has one
 *      address per chain. `msg.value` covers LayerZero messaging fees.
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

    /// @notice EIP-712 typehash binding the local fee signature to the route, nonce, runtime fee, and deadline.
    bytes32 public constant EXECUTE_OFT_TYPEHASH =
        keccak256("ExecuteOFT(bytes32 routeParamsHash,bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    constructor() EIP712("CounterfactualDepositOFT", "v2.0.0") {}

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredOFT (LayerZero). `routeParamsEncoded` is ABI-encoded as `OFTRouteParams`;
     *      `submitterDataEncoded` as `OFTSubmitterData` (includes a signature forwarded to the OFT periphery).
     *      ERC-20 only — the token is the periphery's immutable `TOKEN`. Forwards `msg.value` for LayerZero
     *      messaging fees. The local fee signature binds the route (`routeParamsHash`, which includes the
     *      `peripheryGetter`); `amount` is bound transitively via the periphery quote signature.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        OFTRouteParams memory routeParams = abi.decode(routeParamsEncoded, (OFTRouteParams));
        OFTSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (OFTSubmitterData));

        _verifySignature(keccak256(routeParamsEncoded), submitterData);
        if (submitterData.executionFee > _resolveBeaconUint(routeParams.maxExecutionFeeGetter))
            revert MaxExecutionFee();

        // Periphery chosen by the leaf's selector; input token is that periphery's immutable `TOKEN`.
        address oftSrcPeriphery = _requireConfigured(_resolveBeaconAddress(routeParams.peripheryGetter));
        address inputToken = ISponsoredOFTSrcPeriphery(oftSrcPeriphery).TOKEN();

        // Fee paid before the periphery call (load-bearing): the local signature binds the route and
        // (nonce, fee, deadline) but not `amount`, so amount-replay protection is the periphery's nonce
        // check — a replayed fee reverts at `deposit` and rolls back this transfer.
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

    function _verifySignature(bytes32 routeParamsHash, OFTSubmitterData memory submitterData) private view {
        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_OFT_TYPEHASH,
                routeParamsHash,
                submitterData.nonce,
                submitterData.executionFee,
                submitterData.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != _beacon().signer())
            revert InvalidSignature();
    }

    /// @notice Calls `deposit` on the SponsoredOFTSrcPeriphery with the constructed quote.
    /// @param oftSrcPeriphery The OFT periphery (resolved from the leaf's selector).
    /// @param routeParams Route parameters from the merkle leaf.
    /// @param submitterData Submitter-provided execution data.
    /// @param depositAmount Amount to deposit after deducting the execution fee.
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
