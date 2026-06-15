// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ITokenMessengerV2 } from "../../external/interfaces/CCTPInterfaces.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualImplementationBase } from "./CounterfactualImplementationBase.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Route parameters committed to in the merkle leaf (chain-agnostic: no source chain, no token).
 * @dev Burn token is always USDC (`beacon.usdc()`); the CCTP TokenMessenger from `beacon.cctpTokenMessenger()`.
 *      `hookData` selects the entrypoint: empty ⇒ `depositForBurn` (plain CCTP); non-empty ⇒
 *      `depositForBurnWithHook` (e.g. HyperCore, where `mintRecipient`/`hookData` are Circle's
 *      `CctpForwarder` + envelope, opaque here and built off-chain). Fast vs standard is chosen at
 *      execution time by the submitter (`maxFeeCctp`/`minFinalityThreshold` in the submitter data).
 */
struct VanillaCCTPRouteParams {
    uint32 destinationDomain;
    bytes32 mintRecipient;
    bytes32 destinationCaller;
    bytes hookData;
    /// @dev Selector of the beacon getter for this route's per-chain execution-fee cap (e.g.
    ///      `beacon.usdcCctpMaxExecutionFee.selector`, shared with the sponsored CCTP leaf).
    bytes4 maxExecutionFeeGetter;
    /// @dev Selector of the beacon getter for this route's per-chain cap on the submitter-chosen
    ///      `maxFeeCctp`, in bps of the burned amount (e.g. `beacon.usdcCctpMaxFeeBps.selector`).
    bytes4 cctpMaxFeeBpsGetter;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct VanillaCCTPSubmitterData {
    uint256 amount;
    address executionFeeRecipient;
    uint256 executionFee;
    /// @dev Circle fast-transfer `maxFee` passed to the TokenMessenger (0 ⇒ standard transfer), capped at
    ///      the beacon's `<cctpMaxFeeBpsGetter>` bps of the burned amount.
    uint256 maxFeeCctp;
    uint32 minFinalityThreshold;
    uint32 signatureDeadline;
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositVanillaCCTP
 * @notice Counterfactual deposit via vanilla (non-sponsored) Circle CCTP v2.
 * @dev Delegatecalled by the dispatcher (`address(this)` is the proxy / EIP-712 `verifyingContract`).
 *      Unlike `CounterfactualDepositCCTP`, this calls Circle's `ITokenMessengerV2` directly (no Across
 *      periphery) — USDC mints natively on the destination. TokenMessenger and burn token (USDC) come from
 *      the beacon, so the impl holds no chain-specific values and has one address per chain.
 *
 *      With no periphery quote signature, the local EIP-712 fee signature binds the full route
 *      (`routeParamsHash`), `amount`, `executionFee`, `maxFeeCctp`, `minFinalityThreshold` and
 *      `signatureDeadline`. Replay protection is the short `signatureDeadline` (no nonce). ERC-20 only.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositVanillaCCTP is CounterfactualImplementationBase, EIP712 {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted after a vanilla CCTP deposit is successfully executed.
     * @param amount Total input amount (including execution fee).
     * @param executionFeeRecipient Address that received the execution fee.
     * @param executionFee Execution fee paid to the executor (in input token).
     * @param depositAmount Amount burned via CCTP (`amount - executionFee`).
     */
    event VanillaCCTPDepositExecuted(
        uint256 amount,
        address indexed executionFeeRecipient,
        uint256 executionFee,
        uint256 depositAmount
    );

    error InvalidSignature();
    error SignatureExpired();
    error MaxExecutionFee();
    error MaxCctpFee();

    /// @notice EIP-712 typehash binding the fee signature to the route, amount, runtime fees (executor +
    ///         Circle), finality threshold, and deadline.
    bytes32 public constant EXECUTE_VANILLA_CCTP_TYPEHASH =
        keccak256(
            "ExecuteVanillaCCTP(bytes32 routeParamsHash,uint256 amount,uint256 executionFee,uint256 maxFeeCctp,uint32 minFinalityThreshold,uint32 signatureDeadline)"
        );

    constructor() EIP712("CounterfactualDepositVanillaCCTP", "v2.0.0") {}

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Bridges tokens via Circle CCTP v2. `routeParamsEncoded` is ABI-encoded as `VanillaCCTPRouteParams`;
     *      `submitterDataEncoded` as `VanillaCCTPSubmitterData`. ERC-20 (USDC) only.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        VanillaCCTPRouteParams memory routeParams = abi.decode(routeParamsEncoded, (VanillaCCTPRouteParams));
        VanillaCCTPSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (VanillaCCTPSubmitterData));

        // Sole authorization (no periphery sig): binds the exact leaf params, amount, and fee.
        _verifySignature(keccak256(routeParamsEncoded), submitterData);

        // Each fee is capped independently against the beacon getter its leaf names.
        if (submitterData.executionFee > _resolveBeaconUint(routeParams.maxExecutionFeeGetter))
            revert MaxExecutionFee();
        uint256 depositAmount = submitterData.amount - submitterData.executionFee;
        if (
            submitterData.maxFeeCctp >
            (depositAmount * _resolveBeaconUint(routeParams.cctpMaxFeeBpsGetter)) / BPS_SCALAR
        ) revert MaxCctpFee();

        ITokenMessengerV2 tokenMessenger = ITokenMessengerV2(_requireConfigured(_beacon().cctpTokenMessenger()));
        address inputToken = _requireConfigured(_beacon().usdc());

        if (submitterData.executionFee > 0)
            IERC20(inputToken).safeTransfer(submitterData.executionFeeRecipient, submitterData.executionFee);

        IERC20(inputToken).forceApprove(address(tokenMessenger), depositAmount);

        // Non-empty `hookData` ⇒ `depositForBurnWithHook` (e.g. HyperCore); empty ⇒ plain `depositForBurn`.
        if (routeParams.hookData.length > 0) {
            tokenMessenger.depositForBurnWithHook(
                depositAmount,
                routeParams.destinationDomain,
                routeParams.mintRecipient,
                inputToken,
                routeParams.destinationCaller,
                submitterData.maxFeeCctp,
                submitterData.minFinalityThreshold,
                routeParams.hookData
            );
        } else {
            tokenMessenger.depositForBurn(
                depositAmount,
                routeParams.destinationDomain,
                routeParams.mintRecipient,
                inputToken,
                routeParams.destinationCaller,
                submitterData.maxFeeCctp,
                submitterData.minFinalityThreshold
            );
        }

        emit VanillaCCTPDepositExecuted(
            submitterData.amount,
            submitterData.executionFeeRecipient,
            submitterData.executionFee,
            depositAmount
        );
    }

    function _verifySignature(bytes32 routeParamsHash, VanillaCCTPSubmitterData memory submitterData) private view {
        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_VANILLA_CCTP_TYPEHASH,
                routeParamsHash,
                submitterData.amount,
                submitterData.executionFee,
                submitterData.maxFeeCctp,
                submitterData.minFinalityThreshold,
                submitterData.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != _beacon().signer())
            revert InvalidSignature();
    }
}
