// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualBeacon } from "../../interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CounterfactualImplementationBase } from "./CounterfactualImplementationBase.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @notice Route parameters committed to in the merkle leaf (chain-agnostic: no source chain, no token).
 * @dev `inputTokenGetter` is the selector of the beacon getter resolving the per-chain input token (e.g.
 *      `beacon.usdc.selector`). Native isn't a special selector: the resolved value signals it — the
 *      sentinel (`0xEeee…EEeE`) ⇒ native, any other address ⇒ ERC-20 — so e.g. a `beacon.nativeToken`
 *      leaf is native where the beacon returns the sentinel and ERC-20 where it returns a token.
 *      `destinationChainId`, `outputToken`, `recipient` are the (chain-invariant) destination identity.
 */
struct SpokePoolRouteParams {
    bytes4 inputTokenGetter;
    uint256 destinationChainId;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    bool checkStableExchangeRate;
    uint256 stableExchangeRate;
    /// @dev Selector of the beacon getter for this route's per-chain fixed fee cap (e.g.
    ///      `beacon.usdcSpokePoolMaxExecutionFee.selector`); added to the `maxFeeBps` term below.
    bytes4 maxExecutionFeeGetter;
    uint256 maxFeeBps;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct SpokePoolSubmitterData {
    uint256 inputAmount;
    uint256 outputAmount;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    uint256 executionFee;
    bytes signature;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Counterfactual deposit via Across SpokePool, agnostic to the input token.
 * @dev Delegatecalled by the dispatcher. SpokePool, wrapped native token and fee signer come from the
 *      beacon; the input token from the beacon getter the leaf's `inputTokenGetter` names. Native vs ERC-20
 *      is the resolved value (`NATIVE_SENTINEL` ⇒ msg.value path, input is `beacon.wrappedNativeToken()`;
 *      else ⇒ ERC-20). Holds no chain-specific values; one address per chain.
 *
 *      No per-token variants or per-variant EIP-712 names: `inputTokenGetter` is in `params` →
 *      `routeParamsHash`, which the fee signature binds, so a signature for one token can't validate for
 *      another. Cross-chain replay is prevented by the domain `chainId`, cross-clone by `verifyingContract`.
 *      No nonce needed (balance is consumed on execution; short deadlines bound the window). Depositor
 *      speed-ups are unsupported: `depositor` is `address(this)` (the clone), which can't sign.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePool is CounterfactualImplementationBase, EIP712, SafeTransferERC20 {
    // `using` is restricted to `forceApprove`; `safeTransfer` goes through the `_safeTransfer` hook so
    // chain-specific variants (Tron) can override transfer semantics in one place.
    using { SafeERC20.forceApprove } for IERC20;

    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /// @notice Sentinel returned by `inputTokenGetter` to signal a native route (the Aave/Compound-style
    ///         native-asset placeholder).
    address public constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /**
     * @notice Emitted after a SpokePool deposit is successfully executed.
     * @param inputAmount Total input amount (including execution fee).
     * @param outputAmount Output amount on the destination chain.
     * @param exclusiveRelayer Address of the exclusive relayer (bytes32-encoded).
     * @param exclusivityDeadline Timestamp until which the exclusive relayer has priority.
     * @param executionFeeRecipient Address that received the execution fee.
     * @param quoteTimestamp Timestamp of the deposit quote.
     * @param fillDeadline Deadline by which the deposit must be filled.
     * @param signatureDeadline Deadline after which the authorizing signature expires.
     * @param executionFee Execution fee paid to the executor (in input token).
     */
    event SpokePoolDepositExecuted(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 indexed exclusiveRelayer,
        uint32 exclusivityDeadline,
        address indexed executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        uint256 executionFee
    );

    error MaxFee();
    error InvalidSignature();
    error SignatureExpired();
    error NativeTransferFailed();

    /// @notice EIP-712 typehash for execute deposit signature verification.
    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );

    constructor() EIP712("CounterfactualDepositSpokePool", "v2.0.0") {} // solhint-disable-line no-empty-blocks

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev `routeParamsEncoded`/`submitterDataEncoded` decode to `SpokePoolRouteParams`/`SpokePoolSubmitterData`
     *      (the latter carries the beacon `signer`'s EIP-712 signature). The value resolved from
     *      `inputTokenGetter` decides native (`NATIVE_SENTINEL`, msg.value) vs ERC-20. Reverts:
     *      `SignatureExpired`, `InvalidSignature`, `MaxFee`, `NativeTransferFailed`, `RouteNotConfigured`.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        SpokePoolRouteParams memory routeParams = abi.decode(routeParamsEncoded, (SpokePoolRouteParams));
        SpokePoolSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (SpokePoolSubmitterData));

        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        _verifySignature(keccak256(routeParamsEncoded), submitterData);

        uint256 depositAmount = submitterData.inputAmount - submitterData.executionFee;
        _checkFee(
            routeParams,
            submitterData.inputAmount,
            submitterData.outputAmount,
            depositAmount,
            submitterData.executionFee,
            _resolveBeaconUint(routeParams.maxExecutionFeeGetter)
        );

        ICounterfactualBeacon beacon = _beacon();
        address spokePool = _requireConfigured(beacon.spokePool());

        // The leaf names a beacon getter; its resolved value decides native (`NATIVE_SENTINEL`) vs ERC-20.
        // Branching on the value, not the selector, lets one leaf serve both.
        address resolved = _requireConfigured(_resolveBeaconAddress(routeParams.inputTokenGetter));
        bool isNative = resolved == NATIVE_SENTINEL;
        address inputToken; // ERC-20 to approve/sweep (unused for native)
        bytes32 spokePoolInputToken;
        if (isNative) {
            spokePoolInputToken = bytes32(uint256(uint160(_requireConfigured(beacon.wrappedNativeToken()))));
        } else {
            inputToken = resolved;
            IERC20(inputToken).forceApprove(spokePool, depositAmount);
            spokePoolInputToken = bytes32(uint256(uint160(inputToken)));
        }

        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            routeParams.recipient,
            spokePoolInputToken,
            routeParams.outputToken,
            depositAmount,
            submitterData.outputAmount,
            routeParams.destinationChainId,
            submitterData.exclusiveRelayer,
            submitterData.quoteTimestamp,
            submitterData.fillDeadline,
            submitterData.exclusivityDeadline,
            routeParams.message
        );

        // Pay execution fee
        if (submitterData.executionFee > 0) {
            if (isNative) {
                (bool success, ) = submitterData.executionFeeRecipient.call{ value: submitterData.executionFee }("");
                if (!success) revert NativeTransferFailed();
            } else {
                _safeTransfer(inputToken, submitterData.executionFeeRecipient, submitterData.executionFee);
            }
        }

        emit SpokePoolDepositExecuted(
            submitterData.inputAmount,
            submitterData.outputAmount,
            submitterData.exclusiveRelayer,
            submitterData.exclusivityDeadline,
            submitterData.executionFeeRecipient,
            submitterData.quoteTimestamp,
            submitterData.fillDeadline,
            submitterData.signatureDeadline,
            submitterData.executionFee
        );
    }

    function _checkFee(
        SpokePoolRouteParams memory routeParams,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 depositAmount,
        uint256 executionFee,
        uint256 maxFeeFixed
    ) private pure {
        // With `checkStableExchangeRate` false (non-stable pairs), the rate-derived relayer fee isn't
        // enforced (`outputAmount` is trusted via the signature); `executionFee` is still bounded by `maxFee`.
        uint256 relayerFee;
        if (routeParams.checkStableExchangeRate) {
            uint256 outputInInputToken = (outputAmount * routeParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
            relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        }
        uint256 totalFee = relayerFee + executionFee;
        // `maxFeeFixed` is the per-chain fixed cap resolved from the beacon; `maxFeeBps` stays in the leaf.
        uint256 maxFee = maxFeeFixed + (routeParams.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();
    }

    function _verifySignature(bytes32 routeParamsHash, SpokePoolSubmitterData memory submitterData) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                address(this),
                routeParamsHash,
                submitterData.inputAmount,
                submitterData.outputAmount,
                submitterData.exclusiveRelayer,
                submitterData.exclusivityDeadline,
                submitterData.quoteTimestamp,
                submitterData.fillDeadline,
                submitterData.signatureDeadline,
                submitterData.executionFee
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.signature) != _beacon().signer())
            revert InvalidSignature();
    }
}
