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
 * @notice Route parameters committed to in the merkle leaf.
 */
struct SpokePoolRouteParams {
    uint256 sourceChainId;
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    bool checkStableExchangeRate;
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
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
 * @notice Implementation contract for counterfactual deposits via Across SpokePool.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. EIP-712 domain separator uses
 *      `address(this)` (the clone address) to prevent cross-clone replay attacks. No nonce is needed:
 *      token balance is consumed on execution (natural replay protection), and short deadlines bound the window.
 *
 *      Depositor-driven speed-ups are not supported: the `depositor` passed to `SpokePool.deposit()` is
 *      `address(this)` (the clone), which has no private key and does not implement EIP-1271, and therefore
 *      cannot sign `speedUpV3Deposit` messages.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePool is ICounterfactualImplementation, EIP712, SafeTransferERC20 {
    // Restrict the `using` attachment to `forceApprove` only. All `safeTransfer` calls must go
    // through the `_safeTransfer` hook (inherited from `SafeTransferERC20`) so chain-specific
    // variants can override transfer semantics in one place.
    using { SafeERC20.forceApprove } for IERC20;

    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

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
    error SourceChainMismatch();

    /// @notice EIP-712 typehash for execute deposit signature verification.
    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );

    /// @notice Across SpokePool contract
    address public immutable spokePool;

    /// @notice Signer that authorizes execution parameters
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
     * @dev Deposits into the Across SpokePool. `routeParamsEncoded` is ABI-encoded as `SpokePoolRouteParams`;
     *      `submitterDataEncoded` as `SpokePoolSubmitterData` (includes an EIP-712 signature from `signer`).
     *      Supports native-token deposits. Reverts: `SignatureExpired`, `InvalidSignature`, `MaxFee`,
     *      `NativeTransferFailed`.
     */
    function execute(bytes calldata routeParamsEncoded, bytes calldata submitterDataEncoded) external payable {
        SpokePoolRouteParams memory routeParams = abi.decode(routeParamsEncoded, (SpokePoolRouteParams));
        SpokePoolSubmitterData memory submitterData = abi.decode(submitterDataEncoded, (SpokePoolSubmitterData));

        if (block.chainid != routeParams.sourceChainId) revert SourceChainMismatch();
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
        uint256 executionFee
    ) private pure {
        // When `checkStableExchangeRate` is false (e.g. non-stable pairs), the rate-derived relayer fee
        // is not enforced — `outputAmount` is trusted via the signer's signature — but `executionFee`
        // remains bounded by `maxFee` below.
        uint256 relayerFee;
        if (routeParams.checkStableExchangeRate) {
            uint256 outputInInputToken = (outputAmount * routeParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
            relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        }
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
        if (ECDSA.recover(_hashTypedDataV4(structHash), submitterData.signature) != signer) revert InvalidSignature();
    }
}
