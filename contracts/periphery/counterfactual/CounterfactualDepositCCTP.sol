// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualImplementationBase } from "./CounterfactualImplementationBase.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/// @notice Minimal interface for `depositForBurn` on SponsoredCCTPSrcPeriphery.
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @notice Route parameters committed to in the merkle leaf (chain-agnostic: no source chain, no token).
 * @dev Burn token is always USDC (`beacon.usdc()`); source domain and periphery come from
 *      `beacon.cctpSourceDomain()` / `beacon.cctpSrcPeriphery()`.
 */
struct CCTPRouteParams {
    uint32 destinationDomain;
    bytes32 mintRecipient;
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
    /// @dev Selector of the beacon getter for this route's per-chain execution-fee cap (e.g.
    ///      `beacon.usdcCctpMaxExecutionFee.selector`).
    bytes4 maxExecutionFeeGetter;
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
 * @notice Counterfactual deposit via SponsoredCCTP.
 * @dev Delegatecalled by the dispatcher. Periphery, source domain, burn token (USDC) and fee signer come
 *      from the beacon, so the impl holds no chain-specific values and has one address per chain.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositCCTP is CounterfactualImplementationBase, EIP712 {
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

    /// @notice EIP-712 typehash binding the local fee signature to the route, nonce, runtime fee, and deadline.
    bytes32 public constant EXECUTE_CCTP_TYPEHASH =
        keccak256("ExecuteCCTP(bytes32 routeParamsHash,bytes32 nonce,uint256 executionFee,uint32 signatureDeadline)");

    constructor() EIP712("CounterfactualDepositCCTP", "v2.0.0") {}

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via SponsoredCCTP. `routeParamsEncoded` is ABI-encoded as `CCTPRouteParams`;
     *      `submitterDataEncoded` as `CCTPSubmitterData` (includes a signature forwarded to the CCTP periphery).
     *      ERC-20 (USDC) only. The local fee signature binds the route (`routeParamsHash`); `amount` is
     *      bound transitively via the periphery quote signature forwarded to `srcPeriphery`.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        CCTPRouteParams memory routeParams = abi.decode(routeParamsEncoded, (CCTPRouteParams));
        CCTPSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (CCTPSubmitterData));

        _verifySignature(keccak256(routeParamsEncoded), submitterData);
        if (submitterData.executionFee > _resolveBeaconUint(routeParams.maxExecutionFeeGetter))
            revert MaxExecutionFee();

        address srcPeriphery = _requireConfigured(_beacon().cctpSrcPeriphery());
        address inputToken = _requireConfigured(_beacon().usdc());

        // Fee paid before the periphery call (load-bearing): the local signature binds the route and
        // (nonce, fee, deadline) but not `amount`, so amount-replay protection is the periphery's nonce
        // check — a replayed fee reverts at `depositForBurn` and rolls back this transfer.
        if (submitterData.executionFee > 0)
            IERC20(inputToken).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        uint256 depositAmount = submitterData.amount - submitterData.executionFee;

        IERC20(inputToken).forceApprove(srcPeriphery, depositAmount);

        _depositForBurn(srcPeriphery, inputToken, routeParams, submitterData, depositAmount);

        emit CCTPDepositExecuted(
            submitterData.amount,
            submitterData.executionFeeRecipient,
            submitterData.nonce,
            submitterData.cctpDeadline,
            submitterData.executionFee
        );
    }

    function _verifySignature(bytes32 routeParamsHash, CCTPSubmitterData memory submitterData) private view {
        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_CCTP_TYPEHASH,
                routeParamsHash,
                submitterData.nonce,
                submitterData.executionFee,
                submitterData.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != _beacon().signer())
            revert InvalidSignature();
    }

    /// @notice Calls `depositForBurn` on the SponsoredCCTPSrcPeriphery with the constructed quote.
    /// @param srcPeriphery The CCTP source periphery (from the beacon).
    /// @param inputToken The burn token, USDC (from the beacon).
    /// @param routeParams Route parameters from the merkle leaf.
    /// @param submitterData Submitter-provided execution data.
    /// @param depositAmount Amount to deposit after deducting the execution fee.
    function _depositForBurn(
        address srcPeriphery,
        address inputToken,
        CCTPRouteParams memory routeParams,
        CCTPSubmitterData memory submitterData,
        uint256 depositAmount
    ) private {
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: _beacon().cctpSourceDomain(),
                destinationDomain: routeParams.destinationDomain,
                mintRecipient: routeParams.mintRecipient,
                amount: depositAmount,
                burnToken: bytes32(uint256(uint160(inputToken))),
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
