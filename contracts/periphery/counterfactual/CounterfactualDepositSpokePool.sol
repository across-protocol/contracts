// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET, BPS_SCALAR } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";
import { CloneIdentity } from "./CloneIdentity.sol";

/**
 * @notice Route parameters committed to the merkle leaf. The dispatcher's leaf is agnostic to
 *         clone identity, so this impl binds the leaf to a specific clone by committing
 *         `outputToken` and `destinationChainId` inside `routeParams`. `execute` verifies these
 *         match the dispatcher-forwarded `cloneArgs` values via `CloneIdentity.enforce(...)`.
 *
 *         Identity binding is required here because `stableExchangeRate` is a per-pair assumption
 *         (input token ↔ output token). Without the binding, a clone with a different
 *         `outputToken` could prove the leaf and the fee check would translate amounts using the
 *         wrong rate, allowing fee bounds to be bypassed.
 */
struct SpokePoolRouteParams {
    bytes32 outputToken;
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes message;
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
}

/**
 * @notice Data supplied by the submitter at execution time. `executionFee` is dynamic (set by the
 *         executor, bounded together with the implicit relayer fee by the leaf's
 *         `maxFeeFixed + maxFeeBps × inputAmount` cap) and authorized by `counterfactualSignature`.
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
    bytes counterfactualSignature;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Deposits into an Across SpokePool from a counterfactual clone. Reads destination identity
 *         (recipient, output token, destination chain) from the dispatcher-verified `cloneArgs`.
 * @dev Called via delegatecall from the dispatcher. **Identity-bound at the impl level** via
 *      `CloneIdentity.enforce(...)`: `routeParams.outputToken` and `routeParams.destinationChainId`
 *      must match the dispatcher-forwarded `cloneArgs` values. Binding is required because
 *      `stableExchangeRate` is a per-pair assumption — a leaf authored for one `(inputToken,
 *      outputToken)` pair would produce an incorrect fee bound if executed against a clone with
 *      a different output token.
 *
 *      EIP-712 domain separator uses `address(this)` (the clone) for cross-clone signature replay
 *      safety; the typehash additionally binds `clone` and `routeParamsHash` so signatures are not
 *      reusable across clones or across leaves within a policy.
 *
 *      Depositor-driven speed-ups are not supported: the `depositor` passed to `SpokePool.deposit()`
 *      is `address(this)` (the clone), which has no private key and cannot sign `speedUpV3Deposit`.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePool is ICounterfactualImplementation, EIP712, SafeTransferERC20 {
    // Restrict the `using` attachment to `forceApprove` only. All `safeTransfer` calls must go
    // through the `_safeTransfer` hook (inherited from `SafeTransferERC20`) so chain-specific
    // variants can override transfer semantics in one place.
    using { SafeERC20.forceApprove } for IERC20;

    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /// @notice Emitted after a SpokePool deposit is successfully executed.
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

    /// @notice EIP-712 typehash binding the signature to (clone, leaf, runtime fields).
    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );

    /// @notice Across SpokePool contract.
    address public immutable spokePool;

    /// @notice Signer that authorizes runtime execution parameters (including `executionFee`).
    address public immutable signer;

    /// @notice Wrapped native token address (e.g. WETH) passed to SpokePool for native deposits.
    address public immutable wrappedNativeToken;

    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) EIP712("CounterfactualDepositSpokePool", "v2.0.0") {
        spokePool = _spokePool;
        signer = _signer;
        wrappedNativeToken = _wrappedNativeToken;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev `recipient`/`outputToken`/`destinationChainId` are dispatcher-verified clone identity;
     *      `admin` is unused (this impl is policy-callable and doesn't gate on admin);
     *      `routeParams` is `SpokePoolRouteParams`; `submitterData` is `SpokePoolSubmitterData`.
     *      Supports native-token deposits via `NATIVE_ASSET` sentinel.
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address /* admin */,
        bytes calldata routeParamsEncoded,
        bytes calldata submitterDataEncoded
    ) external payable {
        SpokePoolRouteParams memory routeParams = abi.decode(routeParamsEncoded, (SpokePoolRouteParams));
        SpokePoolSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (SpokePoolSubmitterData));

        // Bind the leaf to this clone's identity. Required because `stableExchangeRate` is a
        // per-pair assumption — see the contract natspec for details.
        CloneIdentity.enforce(routeParams.outputToken, outputToken, routeParams.destinationChainId, destinationChainId);

        if (block.timestamp > submitterData.signatureDeadline) revert SignatureExpired();
        _verifySignature(keccak256(routeParamsEncoded), submitterData);

        address inputToken = address(uint160(uint256(routeParams.inputToken)));
        uint256 depositAmount = submitterData.inputAmount - submitterData.executionFee;

        _checkFee(
            routeParams,
            submitterData.inputAmount,
            submitterData.outputAmount,
            depositAmount,
            submitterData.executionFee
        );

        bool isNative = inputToken == NATIVE_ASSET;
        if (!isNative) IERC20(inputToken).forceApprove(spokePool, depositAmount);

        bytes32 spokePoolInputToken = isNative ? bytes32(uint256(uint160(wrappedNativeToken))) : routeParams.inputToken;
        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            recipient,
            spokePoolInputToken,
            outputToken,
            depositAmount,
            submitterData.outputAmount,
            destinationChainId,
            submitterData.exclusiveRelayer,
            submitterData.quoteTimestamp,
            submitterData.fillDeadline,
            submitterData.exclusivityDeadline,
            routeParams.message
        );

        // Pay execution fee.
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
        uint256 executionFee
    ) private pure {
        uint256 outputInInputToken = (outputAmount * routeParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + executionFee;
        uint256 maxFee = routeParams.maxFeeFixed + (routeParams.maxFeeBps * inputAmount) / BPS_SCALAR;
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
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.counterfactualSignature) != signer)
            revert InvalidSignature();
    }
}
