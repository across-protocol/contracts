// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DonationBox } from "../../chain-adapters/DonationBox.sol";

// Import MulticallHandler
import { MulticallHandler } from "../../handlers/MulticallHandler.sol";

// Import constants
import { BPS_SCALAR } from "./Constants.sol";

/**
 * @title ArbitraryEVMFlowExecutor
 * @notice Base contract for executing arbitrary action sequences using MulticallHandler
 * @dev This contract provides shared functionality for both OFT and CCTP handlers to execute
 * arbitrary actions on HyperEVM via MulticallHandler, with optional transfer to HyperCore.
 * @custom:security-contact bugs@across.to
 */
abstract contract ArbitraryEVMFlowExecutor {
    using SafeERC20 for IERC20;

    /// @notice Compressed call struct (no value field to save gas)
    struct CompressedCall {
        address target;
        bytes callData;
    }

    /// @notice MulticallHandler contract instance
    address public immutable multicallHandler;

    /// @notice Emitted when arbitrary actions are executed successfully
    event ArbitraryActionsExecuted(bytes32 indexed quoteNonce, uint256 callCount, uint256 finalAmount);

    /// @notice Error thrown when final balance is insufficient
    error InsufficientFinalBalance(address token, uint256 expected, uint256 actual);

    uint256 constant BPS_TOTAL_PRECISION = 18;
    uint256 constant BPS_DECIMALS = 4;
    uint256 constant BPS_PRECISION_SCALAR = 10 ** BPS_TOTAL_PRECISION;

    constructor(address _multicallHandler) {
        multicallHandler = _multicallHandler;
    }

    /**
     * @notice Executes arbitrary actions by transferring tokens to MulticallHandler
     * @dev Decompresses CompressedCall[] to MulticallHandler.Call[] format (adds value: 0)
     * @param amount Amount of tokens to transfer to MulticallHandler
     * @param quoteNonce Unique nonce for this quote
     * @param maxBpsToSponsor Maximum basis points to sponsor
     * @param initialToken Token to transfer to MulticallHandler
     * @param finalToken Expected final token after actions
     * @param actionData Encoded actions: abi.encode(CompressedCall[] calls)
     * @param extraFeesToSponsorTokenIn Extra fees to sponsor in initialToken
     */
    function _executeArbitraryActionFlow(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address initialToken,
        address finalToken,
        bytes memory actionData,
        uint256 extraFeesToSponsorTokenIn
    ) internal returns (address /* finalToken */, uint256 finalAmount, uint256 extraFeesToSponsorFinalToken) {
        // Decode the compressed action data
        CompressedCall[] memory compressedCalls = abi.decode(actionData, (CompressedCall[]));

        // Total amount to sponsor is the extra fees to sponsor, ceiling division.
        uint256 totalAmount = amount + extraFeesToSponsorTokenIn;
        uint256 bpsToSponsor = ((extraFeesToSponsorTokenIn * BPS_PRECISION_SCALAR) + totalAmount - 1) / totalAmount;
        uint256 maxBpsToSponsorAdjusted = maxBpsToSponsor * (10 ** (BPS_TOTAL_PRECISION - BPS_DECIMALS));
        if (bpsToSponsor > maxBpsToSponsorAdjusted) {
            bpsToSponsor = maxBpsToSponsorAdjusted;
        }

        // Snapshot balances
        uint256 initialAmountSnapshot = IERC20(initialToken).balanceOf(address(this));
        uint256 finalAmountSnapshot = IERC20(finalToken).balanceOf(address(this));

        // Transfer tokens to MulticallHandler
        IERC20(initialToken).safeTransfer(multicallHandler, amount);

        // Decompress calls: add value: 0 to each call and wrap in Instructions
        // We encode Instructions with calls and a drainLeftoverTokens call at the end
        uint256 callCount = compressedCalls.length;

        // Build instructions for MulticallHandler
        bytes memory instructions = _buildMulticallInstructions(
            compressedCalls,
            finalToken,
            address(this) // Send leftover tokens back to this contract
        );

        // Execute via MulticallHandler
        MulticallHandler(payable(multicallHandler)).handleV3AcrossMessage(
            initialToken,
            amount,
            address(this),
            instructions
        );

        // This means the swap (if one was intended) didn't happen (action failed), so we use the initial token as the final token.
        if (initialAmountSnapshot == IERC20(initialToken).balanceOf(address(this))) {
            finalToken = initialToken;
            finalAmount = amount;
        } else {
            uint256 finalBalance = IERC20(finalToken).balanceOf(address(this));
            if (finalBalance >= finalAmountSnapshot) {
                // This means the swap did happen, so we check the balance of the output token and send it.
                finalAmount = finalBalance - finalAmountSnapshot;
            } else {
                // If we somehow lost final tokens, just set the finalAmount to 0.
                finalAmount = 0;
            }
        }

        // Apply the bps to sponsor to the final amount to get the amount to sponsor, ceiling division.
        uint256 bpsToSponsorAdjusted = BPS_PRECISION_SCALAR - bpsToSponsor;
        extraFeesToSponsorFinalToken =
            (((finalAmount * BPS_PRECISION_SCALAR) + bpsToSponsorAdjusted - 1) / bpsToSponsorAdjusted) -
            finalAmount;

        emit ArbitraryActionsExecuted(quoteNonce, callCount, finalAmount);

        return (finalToken, finalAmount, extraFeesToSponsorFinalToken);
    }

    /**
     * @notice Builds MulticallHandler Instructions from compressed calls
     * @dev Decompresses calls by adding value: 0, and adds drainLeftoverTokens call at the end
     */
    function _buildMulticallInstructions(
        CompressedCall[] memory compressedCalls,
        address finalToken,
        address fallbackRecipient
    ) internal view returns (bytes memory) {
        uint256 callCount = compressedCalls.length;

        // Create Call[] array with value: 0 for each call, plus one for drainLeftoverTokens
        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](callCount + 1);

        // Decompress: add value: 0 to each call
        for (uint256 i = 0; i < callCount; ++i) {
            calls[i] = MulticallHandler.Call({
                target: compressedCalls[i].target,
                callData: compressedCalls[i].callData,
                value: 0
            });
        }

        // Add final call to drain leftover tokens back to this contract
        calls[callCount] = MulticallHandler.Call({
            target: multicallHandler,
            callData: abi.encodeWithSelector(
                MulticallHandler.drainLeftoverTokens.selector,
                finalToken,
                fallbackRecipient
            ),
            value: 0
        });

        // Build Instructions struct
        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            fallbackRecipient: fallbackRecipient
        });

        return abi.encode(instructions);
    }

    /// @notice Allow contract to receive native tokens for arbitrary action execution
    receive() external payable virtual {}
}
