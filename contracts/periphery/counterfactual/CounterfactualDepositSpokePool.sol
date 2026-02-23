// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Parameters passed through to SpokePool.deposit()
 */
struct SpokePoolDepositParams {
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
}

/**
 * @notice SpokePool-specific execution parameters for fee verification
 */
struct SpokePoolExecutionParams {
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
}

/**
 * @notice Combined route parameters for SpokePool deposits
 */
struct SpokePoolImmutables {
    SpokePoolDepositParams depositParams;
    SpokePoolExecutionParams executionParams;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Implementation contract for counterfactual deposits via Across SpokePool, deployed as EIP-1167 clones
 * @dev Unlike CCTP/OFT implementations, this implementation verifies EIP-712 signatures itself since it calls
 *      SpokePool.deposit() directly. The domain separator uses `address(this)` (the clone address)
 *      to prevent cross-clone replay attacks. No nonce is needed: token balance is consumed on
 *      execution (natural replay protection), and short deadlines bound the replay window.
 */
abstract contract CounterfactualDepositSpokePool is CounterfactualDepositBase, EIP712 {
    using SafeERC20 for IERC20;

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

    /**
     * @param _spokePool Across SpokePool contract address.
     * @param _signer Signer that authorizes execution parameters.
     * @param _wrappedNativeToken Wrapped native token address (e.g. WETH).
     */
    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) EIP712("CounterfactualDepositSpokePool", "v1.0.0") {
        spokePool = _spokePool;
        signer = _signer;
        wrappedNativeToken = _wrappedNativeToken;
    }

    /// @dev Accept native ETH sent to the clone (e.g. user deposits or SpokePool refunds).
    receive() external payable {}

    function _executeSpokePoolDeposit(
        SpokePoolImmutables memory params,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature,
        uint256 executionFee
    ) internal virtual {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        _verifySignature(
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            signature
        );

        address inputToken = address(uint160(uint256(params.depositParams.inputToken)));

        uint256 depositAmount = inputAmount - executionFee;

        // Fee check: convert outputAmount to inputToken units, verify total fee within fixed + variable cap
        uint256 outputInInputToken = (outputAmount * params.executionParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + executionFee;
        uint256 maxFee = params.executionParams.maxFeeFixed +
            (params.executionParams.maxFeeBps * inputAmount) /
            BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();

        bool isNative = inputToken == NATIVE_ASSET;
        if (!isNative) IERC20(inputToken).forceApprove(spokePool, depositAmount);

        // Depositor is this clone so expired deposit refunds return here.
        // For native deposits, substitute wrappedNativeToken as inputToken so SpokePool wraps the ETH.
        bytes32 spokePoolInputToken = isNative
            ? bytes32(uint256(uint160(wrappedNativeToken)))
            : params.depositParams.inputToken;
        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            params.depositParams.recipient,
            spokePoolInputToken,
            params.depositParams.outputToken,
            depositAmount,
            outputAmount,
            params.depositParams.destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            params.depositParams.message
        );

        if (executionFee > 0) _transferOut(inputToken, executionFeeRecipient, executionFee);

        emit SpokePoolDepositExecuted(
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            executionFeeRecipient,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline
        );
    }

    /**
     * @dev Verifies that signer authorized execution parameters via EIP-712.
     *      Domain separator includes clone address, preventing cross-clone replay.
     */
    function _verifySignature(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputAmount,
                outputAmount,
                exclusiveRelayer,
                exclusivityDeadline,
                quoteTimestamp,
                fillDeadline,
                signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();
    }
}
