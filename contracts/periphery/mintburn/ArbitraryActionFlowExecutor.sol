// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IMulticallHandler
 * @notice Interface for MulticallHandler contract
 */
interface IMulticallHandler {
    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    struct Instructions {
        Call[] calls;
        address fallbackRecipient;
    }

    function handleV3AcrossMessage(address token, uint256 amount, address relayer, bytes memory message) external;
    function drainLeftoverTokens(address token, address payable destination) external;
}

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
        // Decode the compressed action data
        CompressedCall[] memory compressedCalls = abi.decode(actionData, (CompressedCall[]));

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

        // Snapshot initialToken balance
        uint256 initialAmount = IERC20(initialToken).balanceOf(address(this));

        // Execute via MulticallHandler
        IMulticallHandler(multicallHandler).handleV3AcrossMessage(initialToken, amount, address(this), instructions);

        // This means the swap (if one was intended) didn't happen, so we use the initial token as the final token.
        if (initialAmount == IERC20(initialToken).balanceOf(address(this))) {
            finalToken = initialToken;
        }

        // Check final token balance (now in this contract after drainLeftoverTokens)
        uint256 finalAmount = IERC20(finalToken).balanceOf(address(this));

        emit ArbitraryActionsExecuted(quoteNonce, callCount, finalAmount);

        // Route to appropriate destination based on transferToCore flag
        if (transferToCore) {
            _executeSimpleTransferFlow(finalAmount, quoteNonce, maxBpsToSponsor, finalRecipient, extraFeesToSponsor);
        } else {
            _fallbackHyperEVMFlow(finalAmount, quoteNonce, maxBpsToSponsor, finalRecipient, extraFeesToSponsor);
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
        IMulticallHandler.Call[] memory calls = new IMulticallHandler.Call[](callCount + 1);

        // Decompress: add value: 0 to each call
        for (uint256 i = 0; i < callCount; ++i) {
            calls[i] = IMulticallHandler.Call({
                target: compressedCalls[i].target,
                callData: compressedCalls[i].callData,
                value: 0
            });
        }

        // Add final call to drain leftover tokens back to this contract
        calls[callCount] = IMulticallHandler.Call({
            target: multicallHandler,
            callData: abi.encodeWithSelector(
                IMulticallHandler.drainLeftoverTokens.selector,
                finalToken,
                fallbackRecipient
            ),
            value: 0
        });

        // Build Instructions struct
        IMulticallHandler.Instructions memory instructions = IMulticallHandler.Instructions({
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
        uint256 extraFeesToSponsor
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
        uint256 extraFeesToSponsor
    ) internal virtual;

    /// @notice Allow contract to receive native tokens for arbitrary action execution
    receive() external payable virtual {}
}
