// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import MulticallHandler
import { MulticallHandler } from "../../handlers/MulticallHandler.sol";
import { EVMFlowParams, CommonFlowParams } from "./Structs.sol";

/**
 * @title ArbitraryEVMFlowExecutor
 * @notice Base contract for executing arbitrary action sequences using MulticallHandler
 * @dev This contract provides shared functionality for both OFT and CCTP handlers to execute
 * arbitrary actions on HyperEVM via MulticallHandler, returning information about the resulting token amount
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
    event ArbitraryActionsExecuted(
        bytes32 indexed quoteNonce,
        address indexed initialToken,
        uint256 initialAmount,
        address indexed finalToken,
        uint256 finalAmount
    );

    /// @notice Error thrown when final balance is insufficient
    error InsufficientFinalBalance(address token, uint256 expected, uint256 actual);

    uint256 private constant BPS_TOTAL_PRECISION = 18;
    uint256 private constant BPS_DECIMALS = 4;
    uint256 private constant BPS_PRECISION_SCALAR = 10 ** BPS_TOTAL_PRECISION;

    constructor(address _multicallHandler) {
        multicallHandler = _multicallHandler;
    }

    /**
     * @notice Executes arbitrary actions by transferring tokens to MulticallHandler
     * @dev Decompresses CompressedCall[] to MulticallHandler.Call[] format (adds value: 0)
     * @param params Parameters of HyperEVM execution
     * @return commonParams Parameters to continue sponsored execution to transfer funds to final recipient at correct destination
     */
    function _executeFlow(EVMFlowParams memory params) internal returns (CommonFlowParams memory commonParams) {
        // Decode the compressed action data
        CompressedCall[] memory compressedCalls = abi.decode(params.actionData, (CompressedCall[]));

        // Snapshot balances
        uint256 initialAmountSnapshot = IERC20(params.initialToken).balanceOf(address(this));
        uint256 finalAmountSnapshot = IERC20(params.commonParams.finalToken).balanceOf(address(this));

        // Transfer tokens to MulticallHandler
        IERC20(params.initialToken).safeTransfer(multicallHandler, params.commonParams.amountInEVM);

        // Build instructions for MulticallHandler
        bytes memory instructions = _buildMulticallInstructions(
            compressedCalls,
            params.commonParams.finalToken,
            address(this) // Send leftover tokens back to this contract
        );

        // Execute via MulticallHandler
        MulticallHandler(payable(multicallHandler)).handleV3AcrossMessage(
            params.initialToken,
            params.commonParams.amountInEVM,
            address(this),
            instructions
        );

        uint256 finalAmount;
        // This means the swap (if one was intended) didn't happen (action failed), so we use the initial token as the final token.
        if (initialAmountSnapshot == IERC20(params.initialToken).balanceOf(address(this))) {
            params.commonParams.finalToken = params.initialToken;
            finalAmount = params.commonParams.amountInEVM;
        } else {
            uint256 finalBalance = IERC20(params.commonParams.finalToken).balanceOf(address(this));
            if (finalBalance >= finalAmountSnapshot) {
                // This means the swap did happen, so we check the balance of the output token and send it.
                finalAmount = finalBalance - finalAmountSnapshot;
            } else {
                // If we somehow lost final tokens, just set the finalAmount to 0.
                finalAmount = 0;
            }
        }

        params.commonParams.extraFeesIncurred = _calcExtraFeesFinal(
            params.commonParams.amountInEVM,
            params.commonParams.extraFeesIncurred,
            finalAmount
        );
        params.commonParams.amountInEVM = finalAmount;

        emit ArbitraryActionsExecuted(
            params.commonParams.quoteNonce,
            params.initialToken,
            params.commonParams.amountInEVM,
            params.commonParams.finalToken,
            finalAmount
        );

        return params.commonParams;
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

    /// @notice Calcualtes proportional fees to sponsor in finalToken, given the fees to sponsor in initial token and initial amount
    function _calcExtraFeesFinal(
        uint256 amount,
        uint256 extraFeesToSponsorTokenIn,
        uint256 finalAmount
    ) internal pure returns (uint256 extraFeesToSponsorFinalToken) {
        // Total amount to sponsor is the extra fees to sponsor, ceiling division.
        uint256 bpsToSponsor;
        {
            uint256 totalAmount = amount + extraFeesToSponsorTokenIn;
            bpsToSponsor = ((extraFeesToSponsorTokenIn * BPS_PRECISION_SCALAR) + totalAmount - 1) / totalAmount;
        }

        // Apply the bps to sponsor to the final amount to get the amount to sponsor, ceiling division.
        uint256 bpsToSponsorAdjusted = BPS_PRECISION_SCALAR - bpsToSponsor;
        extraFeesToSponsorFinalToken =
            (((finalAmount * BPS_PRECISION_SCALAR) + bpsToSponsorAdjusted - 1) / bpsToSponsorAdjusted) -
            finalAmount;
    }

    /// @notice Allow contract to receive native tokens for arbitrary action execution
    receive() external payable virtual {}
}
