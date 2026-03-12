// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts-v4/security/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts-v4/access/Ownable.sol";
import { EIP712 } from "@openzeppelin/contracts-v4/utils/cryptography/EIP712.sol";
import { Address } from "@openzeppelin/contracts-v4/utils/Address.sol";
import { TopUpGatewayInterface } from "../interfaces/TopUpGatewayInterface.sol";

/**
 * @title TopUpGateway
 * @notice Signature-gated generic gateway for handling message-based token flows.
 * @dev v0 intentionally supports any caller and any target/selector. Security relies on signed
 * execution envelopes, nonce replay protection, and optional Permit2 top-up pull from relayer.
 */
contract TopUpGateway is TopUpGatewayInterface, ReentrancyGuard, Pausable, Ownable, EIP712 {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bytes32 public constant EXECUTION_DATA_TYPEHASH =
        keccak256(
            "ExecutionData(bytes32 nonce,uint256 deadline,address inputToken,uint256 requiredAmount,address relayer,address refundTo,uint256 topupMax,address target,uint256 value,bytes32 callDataHash)"
        );

    // See IPermit2.permitWitnessTransferFrom witnessTypeString parameter.
    string public constant PERMIT2_WITNESS_TYPE_STRING =
        "ExecutionWitness witness)ExecutionWitness(bytes32 executionHash)";

    IPermit2 public immutable permit2;
    mapping(bytes32 => bool) public usedNonces;

    constructor(IPermit2 _permit2) EIP712("TOP-UP-GATEWAY", "1.0.0") {
        permit2 = _permit2;
    }

    /**
     * @notice Hashes execution data with this contract's EIP-712 domain.
     * @dev Exposed for offchain signing and integration testing.
     */
    function executionDigest(ExecutionData memory execution) public view returns (bytes32) {
        return _hashTypedDataV4(_hashExecution(execution));
    }

    function cancelNonce(bytes32 nonce) external onlyOwner {
        usedNonces[nonce] = true;
        emit NonceCancelled(nonce);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Handles token message execution with signature-bound arbitrary target call.
     * @param tokenSent Token received by this gateway.
     * @param relayedAmount Amount supplied by caller (ignored for accounting; balance based checks are used).
     * @param relayer Relayer address provided by caller.
     * @param message ABI encoded:
     * (ExecutionData execution, IPermit2.PermitTransferFrom permit, bytes permit2Signature)
     */
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 relayedAmount,
        address relayer,
        bytes memory message
    ) external override nonReentrant whenNotPaused {
        relayedAmount; // not used, but kept in signature compatibility.

        (ExecutionData memory execution, IPermit2.PermitTransferFrom memory permit, bytes memory permit2Signature) = abi
            .decode(message, (ExecutionData, IPermit2.PermitTransferFrom, bytes));

        if (execution.deadline < block.timestamp) revert InvalidDeadline();
        if (usedNonces[execution.nonce]) revert NonceAlreadyUsed();
        if (execution.inputToken != tokenSent) revert InputTokenMismatch();
        if (execution.relayer != relayer) revert RelayerMismatch();
        if (permit.permitted.token != execution.inputToken) revert InvalidPermitToken();
        if (permit2Signature.length == 0) revert MissingPermit2Signature();

        usedNonces[execution.nonce] = true;

        bytes32 digest = executionDigest(execution);
        uint256 gatewayBal = IERC20(tokenSent).balanceOf(address(this));
        uint256 topupAmount = 0;
        if (gatewayBal < execution.requiredAmount) {
            topupAmount = execution.requiredAmount - gatewayBal;
            if (topupAmount > execution.topupMax) revert TopupExceedsMax();
        }
        _pullRelayerTopUp(execution, permit, permit2Signature, topupAmount, digest);

        if (IERC20(tokenSent).balanceOf(address(this)) < execution.requiredAmount) {
            revert InsufficientFundsAfterTopup();
        }

        IERC20(tokenSent).forceApprove(execution.target, execution.requiredAmount);
        (bool success, bytes memory data) = execution.target.call{ value: execution.value }(execution.callData);
        IERC20(tokenSent).forceApprove(execution.target, 0);
        if (!success) revert TargetCallFailed(data);

        _refundRemainder(tokenSent, execution.refundTo);

        emit ExecutionCompleted(execution.nonce, execution.target, tokenSent, execution.requiredAmount, topupAmount);
    }

    function _pullRelayerTopUp(
        ExecutionData memory execution,
        IPermit2.PermitTransferFrom memory permit,
        bytes memory permit2Signature,
        uint256 topupAmount,
        bytes32 digest
    ) private {
        if (permit.permitted.amount < topupAmount) {
            revert TopupExceedsMax();
        }

        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: topupAmount
        });

        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            execution.relayer,
            digest,
            PERMIT2_WITNESS_TYPE_STRING,
            permit2Signature
        );

        emit Permit2TopupPulled(execution.nonce, execution.relayer, execution.inputToken, topupAmount);
    }

    function _hashExecution(ExecutionData memory execution) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EXECUTION_DATA_TYPEHASH,
                    execution.nonce,
                    execution.deadline,
                    execution.inputToken,
                    execution.requiredAmount,
                    execution.relayer,
                    execution.refundTo,
                    execution.topupMax,
                    execution.target,
                    execution.value,
                    keccak256(execution.callData)
                )
            );
    }

    function _refundRemainder(address token, address refundTo) private {
        uint256 tokenBal = IERC20(token).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(token).safeTransfer(refundTo, tokenBal);
        }

        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) {
            payable(refundTo).sendValue(nativeBal);
        }
    }

    receive() external payable {}
}
