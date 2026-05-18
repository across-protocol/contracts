// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET, BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `executionFee` is intentionally NOT in this struct — it is supplied at execute time in
 *      `SpokePoolSubmitterData` and authorized by the signer EIP-712 signature.
 */
struct SpokePoolDepositParams {
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
}

/**
 * @notice Data supplied by the submitter at execution time.
 * @dev `executionFee` is signer-authorized via the EIP-712 typehash, so it cannot exceed what the signer
 *      attested for this `(paramsHash, inputAmount, outputAmount, …)` tuple. The fee cap
 *      (`maxFeeFixed + maxFeeBps * inputAmount / 10_000`) bounds it further on top.
 */
struct SpokePoolSubmitterData {
    uint256 inputAmount;
    uint256 outputAmount;
    uint256 executionFee;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Implementation contract for counterfactual deposits via Across SpokePool.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. EIP-712 domain separator uses
 *      `address(this)` (the clone address) to prevent cross-clone replay attacks. No nonce is needed:
 *      token balance is consumed on execution (natural replay protection), and short deadlines bound the window.
 *
 *      The signed payload commits to `keccak256(params)` so a signature issued for one leaf cannot be replayed
 *      against another leaf in the same clone, and binds `executionFee` so the executor cannot inflate it.
 *
 *      Cross-leaf destination consistency is enforced by the merkle root: every leaf's `params` encodes its
 *      destination, so the root commits to every destination the clone can bridge to, and the CREATE2 address
 *      itself binds destination identity. No separate on-chain identity check is required.
 *
 *      Depositor-driven speed-ups are not supported: the `depositor` passed to `SpokePool.deposit()` is
 *      `address(this)` (the clone), which has no private key and does not implement EIP-1271, and therefore
 *      cannot sign `speedUpV3Deposit` messages.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePool is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /**
     * @notice Emitted after a SpokePool deposit is successfully executed.
     * @param inputAmount Total input amount (including execution fee).
     * @param outputAmount Output amount on the destination chain.
     * @param executionFee Fee paid to the executor at execution time (signer-authorized).
     * @param exclusiveRelayer Address of the exclusive relayer (bytes32-encoded).
     * @param exclusivityDeadline Timestamp until which the exclusive relayer has priority.
     * @param executionFeeRecipient Address that received the execution fee.
     * @param quoteTimestamp Timestamp of the deposit quote.
     * @param fillDeadline Deadline by which the deposit must be filled.
     * @param signatureDeadline Deadline after which the authorizing signature expires.
     */
    event SpokePoolDepositExecuted(
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 executionFee,
        bytes32 indexed exclusiveRelayer,
        uint32 exclusivityDeadline,
        address indexed executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    );

    error MaxFee();
    error InvalidSignature();
    error SignatureExpired();
    error NativeTransferFailed();

    /// @notice EIP-712 typehash for execute deposit signature verification.
    /// @dev Binds `paramsHash` (so signatures don't cross leaves) and `executionFee` (so the executor cannot
    ///      inflate the runtime-supplied fee). Together with `signatureDeadline`, this constrains the
    ///      executor to fee/amount values the signer attested for this specific leaf.
    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(bytes32 paramsHash,uint256 inputAmount,uint256 outputAmount,uint256 executionFee,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
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
    ) EIP712("CounterfactualDepositSpokePool", "v1.0.0") {
        spokePool = _spokePool;
        signer = _signer;
        wrappedNativeToken = _wrappedNativeToken;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Deposits into the Across SpokePool. `params` is ABI-encoded as `SpokePoolDepositParams`;
     *      `submitterData` as `SpokePoolSubmitterData` (includes the runtime-supplied `executionFee` and an
     *      EIP-712 signature from `signer` over `keccak256(params)` plus all execution-time fields).
     *      Supports native-token deposits. Reverts: `SignatureExpired`, `InvalidSignature`, `MaxFee`,
     *      `NativeTransferFailed`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        SpokePoolDepositParams memory dp = abi.decode(params, (SpokePoolDepositParams));
        SpokePoolSubmitterData memory sd = abi.decode(submitterData, (SpokePoolSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifySignature(keccak256(params), sd);

        address inputToken = address(uint160(uint256(dp.inputToken)));
        uint256 depositAmount = sd.inputAmount - sd.executionFee;

        _checkFee(dp, sd.inputAmount, sd.outputAmount, sd.executionFee, depositAmount);

        bool isNative = inputToken == NATIVE_ASSET;
        if (!isNative) IERC20(inputToken).forceApprove(spokePool, depositAmount);

        bytes32 spokePoolInputToken = isNative ? bytes32(uint256(uint160(wrappedNativeToken))) : dp.inputToken;
        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            dp.recipient,
            spokePoolInputToken,
            dp.outputToken,
            depositAmount,
            sd.outputAmount,
            dp.destinationChainId,
            sd.exclusiveRelayer,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.exclusivityDeadline,
            dp.message
        );

        // Pay execution fee
        if (sd.executionFee > 0) {
            if (isNative) {
                (bool success, ) = sd.executionFeeRecipient.call{ value: sd.executionFee }("");
                if (!success) revert NativeTransferFailed();
            } else {
                IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, sd.executionFee);
            }
        }

        emit SpokePoolDepositExecuted(
            sd.inputAmount,
            sd.outputAmount,
            sd.executionFee,
            sd.exclusiveRelayer,
            sd.exclusivityDeadline,
            sd.executionFeeRecipient,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.signatureDeadline
        );
    }

    function _checkFee(
        SpokePoolDepositParams memory dp,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 executionFee,
        uint256 depositAmount
    ) private pure {
        uint256 outputInInputToken = (outputAmount * dp.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + executionFee;
        uint256 maxFee = dp.maxFeeFixed + (dp.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();
    }

    function _verifySignature(bytes32 paramsHash, SpokePoolSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                paramsHash,
                sd.inputAmount,
                sd.outputAmount,
                sd.executionFee,
                sd.exclusiveRelayer,
                sd.exclusivityDeadline,
                sd.quoteTimestamp,
                sd.fillDeadline,
                sd.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.signature) != signer) revert InvalidSignature();
    }
}
