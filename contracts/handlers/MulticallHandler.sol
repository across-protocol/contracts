// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokePoolMessageHandler.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Across Multicall contract that allows a user to specify a series of calls that should be made by the handler
 * via the message field in the deposit.
 * @dev This contract makes the calls blindly. The contract will send any remaining tokens The caller should ensure that the tokens recieved by the handler are completely consumed.
 */
contract MulticallHandler is AcrossMessageHandler, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    struct Replacement {
        address token;
        uint256 offset;
    }

    struct Instructions {
        //  Calls that will be attempted.
        Call[] calls;
        // Where the tokens go if any part of the call fails.
        // Leftover tokens are sent here as well if the action succeeds.
        address fallbackRecipient;
    }

    // Emitted when one of the calls fails. Note: all calls are reverted in this case.
    event CallsFailed(Call[] calls, address indexed fallbackRecipient);

    // Emitted when there are leftover tokens that are sent to the fallbackRecipient.
    event DrainedTokens(address indexed recipient, address indexed token, uint256 indexed amount);

    // Errors
    error CallReverted(uint256 index, Call[] calls);
    error NotSelf();
    error InvalidCall(uint256 index, Call[] calls);
    error ReplacementCallFailed(bytes callData);
    error CalldataTooShort(uint256 callDataLength, uint256 offset);

    modifier onlySelf() {
        _requireSelf();
        _;
    }

    /**
     * @notice Main entrypoint for the handler called by the SpokePool contract.
     * @dev This will execute all calls encoded in the msg. The caller is responsible for making sure all tokens are
     * drained from this contract by the end of the series of calls. If not, they can be stolen.
     * A drainLeftoverTokens call can be included as a way to drain any remaining tokens from this contract.
     * @param message abi encoded array of Call structs, containing a target, callData, and value for each call that
     * the contract should make.
     */
    function handleV3AcrossMessage(address token, uint256, address, bytes memory message) external nonReentrant {
        Instructions memory instructions = abi.decode(message, (Instructions));

        // If there is no fallback recipient, call and revert if the inner call fails.
        if (instructions.fallbackRecipient == address(0)) {
            this.attemptCalls(instructions.calls);
            return;
        }

        // Otherwise, try the call and send to the fallback recipient if any tokens are leftover.
        (bool success, ) = address(this).call(abi.encodeCall(this.attemptCalls, (instructions.calls)));
        if (!success) emit CallsFailed(instructions.calls, instructions.fallbackRecipient);

        // If there are leftover tokens, send them to the fallback recipient regardless of execution success.
        _drainRemainingTokens(token, payable(instructions.fallbackRecipient));
    }

    function attemptCalls(Call[] memory calls) external onlySelf {
        uint256 length = calls.length;
        for (uint256 i = 0; i < length; ++i) {
            Call memory call = calls[i];

            // If we are calling an EOA with calldata, assume target was incorrectly specified and revert.
            if (call.callData.length > 0 && call.target.code.length == 0) {
                revert InvalidCall(i, calls);
            }

            (bool success, ) = call.target.call{ value: call.value }(call.callData);
            if (!success) revert CallReverted(i, calls);
        }
    }

    function drainLeftoverTokens(address token, address payable destination) external onlySelf {
        _drainRemainingTokens(token, destination);
    }

    function _drainRemainingTokens(address token, address payable destination) internal {
        if (token != address(0)) {
            // ERC20 token.
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount > 0) {
                IERC20(token).safeTransfer(destination, amount);
                emit DrainedTokens(destination, token, amount);
            }
        } else {
            // Send native token
            uint256 amount = address(this).balance;
            if (amount > 0) {
                destination.sendValue(amount);
            }
        }
    }

    /**
     * @notice Executes a call while replacing specified calldata offsets with current token/native balances.
     * @dev Modifies calldata in-place using OR operations. Target calldata positions must be zeroed out.
     * Cannot handle negative balances, making it incompatible with DEXs requiring negative input amounts.
     * For native balance (token = address(0)), the entire balance is used as call value.
     * @param target The contract address to call
     * @param callData The calldata to execute, with zero values at replacement positions
     * @param value The native token value to send (ignored if native balance replacement is used)
     * @param replacement Array of Replacement structs specifying token addresses and byte offsets for balance injection
     */
    function makeCallWithBalance(
        address target,
        bytes memory callData,
        uint256 value,
        Replacement[] calldata replacement
    ) external onlySelf {
        for (uint256 i = 0; i < replacement.length; i++) {
            uint256 bal = 0;
            if (replacement[i].token != address(0)) {
                bal = IERC20(replacement[i].token).balanceOf(address(this));
            } else {
                bal = address(this).balance;

                // If we're using the native balance, we assume that the caller wants to send the full value to the target.
                value = bal;
            }

            // + 32 to skip the length of the calldata
            uint256 offset = replacement[i].offset + 32;

            // 32 has already been added to the offset, and the replacement value is 32 bytes long, so
            // we don't need to add 32 here. We just directly compare the offset with the length of the calldata.
            if (offset > callData.length) revert CalldataTooShort(callData.length, offset);

            assembly ("memory-safe") {
                // Get the pointer to the offset that the caller wants to overwrite.
                let ptr := add(callData, offset)
                // Get the current value at the offset.
                let current := mload(ptr)
                // Or the current value with the new value.
                // Reasoning:
                // - caller should 0-out any portion that they want overwritten.
                // - if the caller is representing the balance in a smaller integer, like a uint160 or uint128,
                //   the higher bits will be 0 and not overwrite any other data in the calldata assuming
                //   the balance is small enough to fit in the smaller integer.
                // - The catch: the smaller integer where they want to store the balance must end no
                //   earlier than the 32nd byte in their calldata. Otherwise, this would require a
                //   negative offset, which is not possible.
                let val := or(bal, current)
                // Store the new value at the offset.
                mstore(ptr, val)
            }
        }

        (bool success, ) = target.call{ value: value }(callData);
        if (!success) revert ReplacementCallFailed(callData);
    }

    function _requireSelf() internal view {
        // Must be called by this contract to ensure that this cannot be triggered without the explicit consent of the
        // depositor (for a valid relay).
        if (msg.sender != address(this)) revert NotSelf();
    }

    // Used if the caller is trying to unwrap the native token to this contract.
    receive() external payable {}
}
