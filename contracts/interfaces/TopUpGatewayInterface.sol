// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AcrossMessageHandler } from "./SpokePoolMessageHandler.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";

/**
 * @title TopUpGatewayInterface
 * @notice Interface for TopUpGateway.
 */
interface TopUpGatewayInterface is AcrossMessageHandler {
    struct ExecutionData {
        bytes32 nonce;
        uint256 deadline;
        address inputToken;
        uint256 requiredAmount;
        address relayer;
        address refundTo;
        uint256 topupMax;
        address target;
        uint256 value;
        bytes callData;
    }

    error InvalidDeadline();
    error NonceAlreadyUsed();
    error InputTokenMismatch();
    error RelayerMismatch();
    error InvalidPermitToken();
    error MissingPermit2Signature();
    error TopupExceedsMax();
    error InsufficientFundsAfterTopup();
    error TargetCallFailed(bytes data);

    event NonceCancelled(bytes32 indexed nonce);
    event Permit2TopupPulled(bytes32 indexed nonce, address indexed relayer, address indexed token, uint256 amount);
    event ExecutionCompleted(
        bytes32 indexed nonce,
        address indexed target,
        address indexed token,
        uint256 requiredAmount,
        uint256 topupAmount
    );

    function PERMIT2_WITNESS_TYPE_STRING() external view returns (string memory);

    function permit2() external view returns (IPermit2);

    function usedNonces(bytes32 nonce) external view returns (bool);

    function executionDigest(ExecutionData memory execution) external view returns (bytes32);

    function cancelNonce(bytes32 nonce) external;

    function pause() external;

    function unpause() external;
}
