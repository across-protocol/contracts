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
 * @notice Parameters used by the clone's execution logic
 */
struct SpokePoolExecutionParams {
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
    uint256 executionFee;
    address userWithdrawAddress;
    address adminWithdrawAddress;
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
contract CounterfactualDepositSpokePool is CounterfactualDepositBase, EIP712 {
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

    /**
     * @notice Executes a deposit via Across SpokePool
     * @param params Route parameters (verified against stored hash)
     * @param inputAmount Gross amount of inputToken (includes executionFee)
     * @param outputAmount Amount of outputToken user should receive on dst
     * @param exclusiveRelayer Optional exclusive relayer (bytes32(0) for none)
     * @param exclusivityDeadline Seconds of relayer exclusivity (0 for none)
     * @param executionFeeRecipient Address that receives the execution fee
     * @param quoteTimestamp Quote timestamp from Across API (SpokePool validates recency)
     * @param fillDeadline Timestamp by which the deposit must be filled
     * @param signatureDeadline Timestamp after which the signature is no longer valid
     * @param signature EIP-712 signature from signer over signed arguments
     */
    function executeDeposit(
        SpokePoolImmutables memory params,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) external verifyParamsHash(keccak256(abi.encode(params))) {
        _executeSpokePoolDeposit(
            params,
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            executionFeeRecipient,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            signature
        );
    }

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
        bytes calldata signature
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

        // amount to deposit into SpokePool
        uint256 depositAmount = inputAmount - params.executionParams.executionFee;

        // Fee check: convert outputAmount to inputToken units, verify total fee within fixed + variable cap
        uint256 outputInInputToken = (outputAmount * params.executionParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + params.executionParams.executionFee;
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

        // Pay execution fee
        if (params.executionParams.executionFee > 0)
            _transferOut(inputToken, executionFeeRecipient, params.executionParams.executionFee);

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

    /// @inheritdoc CounterfactualDepositBase
    function _getUserWithdrawAddress(bytes calldata params) internal pure virtual override returns (address) {
        return abi.decode(params, (SpokePoolImmutables)).executionParams.userWithdrawAddress;
    }

    /// @inheritdoc CounterfactualDepositBase
    function _getAdminWithdrawAddress(bytes calldata params) internal pure virtual override returns (address) {
        return abi.decode(params, (SpokePoolImmutables)).executionParams.adminWithdrawAddress;
    }

    /**
     * @dev Verifies that signer authorized execution parameters via EIP-712.
     *      Domain separator includes clone address, preventing cross-clone replay.
     * @param inputAmount Gross input amount (signed by signer).
     * @param outputAmount Output amount on destination (signed by signer).
     * @param exclusiveRelayer Optional exclusive relayer (signed by signer).
     * @param exclusivityDeadline Seconds of relayer exclusivity (signed by signer).
     * @param quoteTimestamp Quote timestamp from Across API (signed by signer).
     * @param fillDeadline Fill deadline timestamp (signed by signer).
     * @param signatureDeadline Signature expiry timestamp (signed by signer).
     * @param signature EIP-712 signature from signer.
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
