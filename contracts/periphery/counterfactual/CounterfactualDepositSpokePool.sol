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

/**
 * @notice Route parameters committed to the merkle leaf. Clone identity (`destinationChainId`,
 *         `outputToken`) is bound into the leaf preimage by the dispatcher, not duplicated here.
 */
struct SpokePoolDepositParams {
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
 * @dev Called via delegatecall from the dispatcher. EIP-712 domain separator uses `address(this)`
 *      (the clone) for cross-clone replay safety; the typehash additionally binds `clone` and
 *      `routeParamsHash` so signatures are not reusable across clones or across leaves within a policy.
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
     *      `routeParams` is `SpokePoolDepositParams`; `submitterData` is `SpokePoolSubmitterData`.
     *      Supports native-token deposits via `NATIVE_ASSET` sentinel.
     */
    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address /* admin */,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) external payable {
        SpokePoolDepositParams memory dp = abi.decode(routeParams, (SpokePoolDepositParams));
        SpokePoolSubmitterData memory sd = abi.decode(submitterData, (SpokePoolSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifySignature(keccak256(routeParams), sd);

        address inputToken = address(uint160(uint256(dp.inputToken)));
        uint256 depositAmount = sd.inputAmount - sd.executionFee;

        _checkFee(dp, sd.inputAmount, sd.outputAmount, depositAmount, sd.executionFee);

        bool isNative = inputToken == NATIVE_ASSET;
        if (!isNative) IERC20(inputToken).forceApprove(spokePool, depositAmount);

        bytes32 spokePoolInputToken = isNative ? bytes32(uint256(uint160(wrappedNativeToken))) : dp.inputToken;
        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            recipient,
            spokePoolInputToken,
            outputToken,
            depositAmount,
            sd.outputAmount,
            destinationChainId,
            sd.exclusiveRelayer,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.exclusivityDeadline,
            dp.message
        );

        // Pay execution fee.
        if (sd.executionFee > 0) {
            if (isNative) {
                (bool success, ) = sd.executionFeeRecipient.call{ value: sd.executionFee }("");
                if (!success) revert NativeTransferFailed();
            } else {
                _safeTransfer(inputToken, sd.executionFeeRecipient, sd.executionFee);
            }
        }

        emit SpokePoolDepositExecuted(
            sd.inputAmount,
            sd.outputAmount,
            sd.exclusiveRelayer,
            sd.exclusivityDeadline,
            sd.executionFeeRecipient,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.signatureDeadline,
            sd.executionFee
        );
    }

    function _checkFee(
        SpokePoolDepositParams memory dp,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 depositAmount,
        uint256 executionFee
    ) private pure {
        uint256 outputInInputToken = (outputAmount * dp.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + executionFee;
        uint256 maxFee = dp.maxFeeFixed + (dp.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();
    }

    function _verifySignature(bytes32 routeParamsHash, SpokePoolSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                address(this),
                routeParamsHash,
                sd.inputAmount,
                sd.outputAmount,
                sd.exclusiveRelayer,
                sd.exclusivityDeadline,
                sd.quoteTimestamp,
                sd.fillDeadline,
                sd.signatureDeadline,
                sd.executionFee
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.counterfactualSignature) != signer)
            revert InvalidSignature();
    }
}
