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
 * @title ArbitraryActionFlowExecutor
 * @notice Base contract for executing arbitrary action sequences using MulticallHandler
 * @dev This contract provides shared functionality for both OFT and CCTP handlers to execute
 * arbitrary actions on HyperEVM via MulticallHandler, with optional transfer to HyperCore.
 * @custom:security-contact bugs@across.to
 */
abstract contract ArbitraryActionFlowExecutor {
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
     * @param finalRecipient Final recipient address
     * @param finalToken Expected final token after actions
     * @param actionData Encoded actions: abi.encode(CompressedCall[] calls)
     * @param transferToCore Whether to transfer result to HyperCore
     * @param extraFeesToSponsor Extra fees to sponsor
     */
    function _executeArbitraryActionFlow(
        uint256 amount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address initialToken,
        address finalRecipient,
        address finalToken,
        bytes memory actionData,
        bool transferToCore,
        uint256 extraFeesToSponsor
    ) internal {
        // Compute bps to sponsor (ceiling division)
        uint256 bpsToSponsor;
        {
            uint256 totalAmount = amount + extraFeesToSponsor;
            uint256 computedBps = ((extraFeesToSponsor * BPS_PRECISION_SCALAR) + totalAmount - 1) / totalAmount;
            uint256 maxBpsToSponsorAdjusted = maxBpsToSponsor * (10 ** (BPS_TOTAL_PRECISION - BPS_DECIMALS));
            bpsToSponsor = computedBps > maxBpsToSponsorAdjusted ? maxBpsToSponsorAdjusted : computedBps;
        }

        // Execute multicall and determine final token/amount
        (uint256 callCount, uint256 finalAmount, address resolvedFinalToken) = _executeMulticallAndResolveFinal(
            amount,
            initialToken,
            finalToken,
            actionData
        );

        // Compute and withdraw sponsorship
        uint256 amountToSponsor = _computeAndWithdrawSponsorship(finalAmount, bpsToSponsor, resolvedFinalToken);

        emit ArbitraryActionsExecuted(quoteNonce, callCount, finalAmount);

        // Route to appropriate destination based on transferToCore flag
        if (transferToCore) {
            _executeSimpleTransferFlow(
                finalAmount,
                quoteNonce,
                maxBpsToSponsor,
                finalRecipient,
                amountToSponsor,
                resolvedFinalToken
            );
        } else {
            _fallbackHyperEVMFlow(
                finalAmount,
                quoteNonce,
                maxBpsToSponsor,
                finalRecipient,
                amountToSponsor,
                resolvedFinalToken
            );
        }
    }

    /**
     * @notice Executes multicall and resolves final token and amount
     * @return callCount Number of calls executed
     * @return finalAmount Final amount after execution
     * @return resolvedFinalToken Final token (may differ from expected if swap failed)
     */
    function _executeMulticallAndResolveFinal(
        uint256 amount,
        address initialToken,
        address finalToken,
        bytes memory actionData
    ) internal returns (uint256 callCount, uint256 finalAmount, address resolvedFinalToken) {
        CompressedCall[] memory compressedCalls = abi.decode(actionData, (CompressedCall[]));
        callCount = compressedCalls.length;

        // Snapshot balances
        uint256 initialSnapshot = IERC20(initialToken).balanceOf(address(this));
        uint256 finalSnapshot = IERC20(finalToken).balanceOf(address(this));

        // Transfer tokens to MulticallHandler and execute
        IERC20(initialToken).safeTransfer(multicallHandler, amount);
        MulticallHandler(payable(multicallHandler)).handleV3AcrossMessage(
            initialToken,
            amount,
            address(this),
            _buildMulticallInstructions(compressedCalls, finalToken, address(this))
        );

        // Determine final token and amount based on balance changes
        if (initialSnapshot == IERC20(initialToken).balanceOf(address(this))) {
            // Swap didn't happen, use initial token
            resolvedFinalToken = initialToken;
            finalAmount = amount;
        } else {
            uint256 finalBalance = IERC20(finalToken).balanceOf(address(this));
            resolvedFinalToken = finalToken;
            finalAmount = finalBalance >= finalSnapshot ? (finalBalance - finalSnapshot) : 0;
        }
    }

    /**
     * @notice Computes sponsorship amount and withdraws from donation box if available
     * @return amountToSponsor Amount withdrawn from donation box (0 if insufficient)
     */
    function _computeAndWithdrawSponsorship(
        uint256 finalAmount,
        uint256 bpsToSponsor,
        address token
    ) internal returns (uint256 amountToSponsor) {
        uint256 bpsToSponsorAdjusted = BPS_PRECISION_SCALAR - bpsToSponsor;
        amountToSponsor =
            (((finalAmount * BPS_PRECISION_SCALAR) + bpsToSponsorAdjusted - 1) / bpsToSponsorAdjusted) -
            finalAmount;

        if (amountToSponsor > 0) {
            DonationBox donationBox = _getDonationBox();
            if (IERC20(token).balanceOf(address(donationBox)) < amountToSponsor) {
                amountToSponsor = 0;
            } else {
                donationBox.withdraw(IERC20(token), amountToSponsor);
            }
        }
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

    /**
     * @notice Execute simple transfer flow to HyperCore with the final token
     * @dev Must be implemented by contracts that inherit from this contract
     */
    function _executeSimpleTransferFlow(
        uint256 finalAmount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        uint256 extraFeesToSponsor,
        address finalToken
    ) internal virtual;

    /**
     * @notice Execute fallback HyperEVM flow (stay on HyperEVM)
     * @dev Must be implemented by contracts that inherit from this contract
     */
    function _fallbackHyperEVMFlow(
        uint256 finalAmount,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalRecipient,
        uint256 extraFeesToSponsor,
        address finalToken
    ) internal virtual;

    /**
     * @notice Get the donation box instance
     * @dev Must be implemented by contracts that inherit from this contract
     */
    function _getDonationBox() internal view virtual returns (DonationBox);

    /// @notice Allow contract to receive native tokens for arbitrary action execution
    receive() external payable virtual {}
}
