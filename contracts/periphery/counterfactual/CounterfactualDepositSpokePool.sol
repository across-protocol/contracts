// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

struct SpokePoolDepositParams {
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
}

struct SpokePoolExecutionParams {
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
    uint256 executionFee;
}

struct SpokePoolRoute {
    SpokePoolDepositParams depositParams;
    SpokePoolExecutionParams executionParams;
}

abstract contract CounterfactualDepositSpokePoolModule is CounterfactualDepositBase, EIP712 {
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

    address public immutable spokePool;
    address public immutable signer;
    address public immutable wrappedNativeToken;

    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) EIP712("CounterfactualDepositMultiBridge", "v1.0.0") {
        spokePool = _spokePool;
        signer = _signer;
        wrappedNativeToken = _wrappedNativeToken;
    }

    function _spokePoolRouteHash(SpokePoolRoute memory route) internal pure returns (bytes32) {
        return keccak256(abi.encode(route));
    }

    function _executeSpokePoolRoute(
        SpokePoolRoute memory route,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        _verifySpokePoolSignature(
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            signature
        );

        address inputToken = address(uint160(uint256(route.depositParams.inputToken)));
        uint256 depositAmount = inputAmount - route.executionParams.executionFee;

        uint256 outputInInputToken = (outputAmount * route.executionParams.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + route.executionParams.executionFee;
        uint256 maxFee = route.executionParams.maxFeeFixed +
            (route.executionParams.maxFeeBps * inputAmount) /
            BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();

        bool isNative = inputToken == NATIVE_ASSET;
        if (!isNative) IERC20(inputToken).forceApprove(spokePool, depositAmount);

        bytes32 spokePoolInputToken = isNative
            ? bytes32(uint256(uint160(wrappedNativeToken)))
            : route.depositParams.inputToken;
        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            route.depositParams.recipient,
            spokePoolInputToken,
            route.depositParams.outputToken,
            depositAmount,
            outputAmount,
            route.depositParams.destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            route.depositParams.message
        );

        if (route.executionParams.executionFee > 0) {
            _transferOut(inputToken, executionFeeRecipient, route.executionParams.executionFee);
        }

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

    function _verifySpokePoolSignature(
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
