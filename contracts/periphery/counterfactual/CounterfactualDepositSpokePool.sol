// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @notice Route parameters committed to in the merkle leaf.
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
    uint256 executionFee;
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
    bytes signature;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Implementation contract for counterfactual deposits via Across SpokePool.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. EIP-712 domain separator uses
 *      `address(this)` (the clone address) to prevent cross-clone replay attacks. No nonce is needed:
 *      token balance is consumed on execution (natural replay protection), and short deadlines bound the window.
 */
contract CounterfactualDepositSpokePool is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_SCALAR = 10_000;
    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;
    address public constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event SpokePoolDepositExecuted(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    );

    error MaxFee();
    error InvalidSignature();
    error SignatureExpired();
    error NativeTransferFailed();

    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
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

    /// @inheritdoc ICounterfactualImplementation
    function execute(bytes calldata params, bytes calldata submitterData) external payable returns (bytes memory) {
        SpokePoolDepositParams memory dp = abi.decode(params, (SpokePoolDepositParams));
        SpokePoolSubmitterData memory sd = abi.decode(submitterData, (SpokePoolSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifySignature(sd);

        address inputToken = address(uint160(uint256(dp.inputToken)));
        uint256 depositAmount = sd.inputAmount - dp.executionFee;

        _checkFee(dp, sd.inputAmount, sd.outputAmount, depositAmount);

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
        if (dp.executionFee > 0) {
            if (isNative) {
                (bool success, ) = sd.executionFeeRecipient.call{ value: dp.executionFee }("");
                if (!success) revert NativeTransferFailed();
            } else {
                IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, dp.executionFee);
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
            sd.signatureDeadline
        );

        return "";
    }

    function _checkFee(
        SpokePoolDepositParams memory dp,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 depositAmount
    ) internal pure {
        uint256 outputInInputToken = (outputAmount * dp.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + dp.executionFee;
        uint256 maxFee = dp.maxFeeFixed + (dp.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();
    }

    function _verifySignature(SpokePoolSubmitterData memory sd) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                sd.inputAmount,
                sd.outputAmount,
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
