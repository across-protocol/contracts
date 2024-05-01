// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Across Multicall contract that allows a user to specify a series of calls that should be made by the handler
 * via the message field in the deposit.
 * @dev This contract makes the calls blindly. The caller should ensure that the tokens recieved by the handler are completely consumed.
 */
contract AcrossMulticall is AcrossMessageHandler, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    error CallReverted(uint256 index);
    error NotSelf();

    /**
     * @notice Main entrypoint for the handler called by the SpokePool contract.
     * @dev This will execute all calls encoded in the msg. The caller is responsible for making sure all tokens are
     * drained from this contract by the end of the series of calls. If not, they can be stolen.
     * A drainRemainingTokens call can be included as a way to drain any remaining tokens from this contract.
     * @param message abi encoded array of Call structs, containing a target, callData, and value for each call that
     * the contract should make.
     */
    function handleV3AcrossMessage(
        address,
        uint256,
        address,
        bytes memory message
    ) external nonReentrant {
        Call[] memory calls = abi.decode(message, (Call[]));

        uint256 length = calls.length;
        for (uint256 i = 0; i < length; i++) {
            Call memory call = calls[i];
            (bool success, ) = call.target.call{ value: call.value }(call.callData);
            if (!success) revert CallReverted(i);
        }
    }

    /**
     * @notice Special function allowing a depositor to send any remaining token balance in this contract
     * at the end of their transaction to a destination address.
     * @dev This function can only be called by this contract to prevent a malicious interaction from draining the user's tokens.
     * This is intentionally not re-entrancy guarded, since the only allowed flow is for this to be called by this contract.
     * @param token the address of the token to drain. If the native balance should be drained, this should be set to
     * 0x0.
     * @param destination the address the remaining tokens should be sent to.
     */
    function drainRemainingTokens(address token, address payable destination) external {
        // Must be called by this contract to ensure that this cannot be triggered without the explicit consent of the
        // depositor (for a valid relay).
        if (msg.sender != address(this)) revert NotSelf();

        // If token address is 0x0, send the native token.
        if (token == address(0)) {
            destination.sendValue(address(this).balance);
        } else {
            // Otherwise, send the provided token address to the destination.
            IERC20(token).safeTransfer(destination, IERC20(token).balanceOf(address(this)));
        }
    }

    // Used if the caller is trying to unwrap the native token to this contract.
    receive() external payable {}
}
