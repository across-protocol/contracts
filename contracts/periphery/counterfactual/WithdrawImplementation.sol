// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";

/**
 * @notice Withdrawal parameters committed to in the merkle leaf.
 * @param authorizedCaller Address authorized to execute this withdrawal leaf.
 * @param forcedRecipient If non-zero, the withdrawal must go to this address. If zero, any recipient is allowed.
 */
struct WithdrawParams {
    address authorizedCaller;
    address forcedRecipient;
}

/**
 * @title WithdrawImplementation
 * @notice Handles token/ETH withdrawals as a merkle leaf implementation.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. `address(this)` is the clone
 *      and `msg.sender` is the original caller.
 */
contract WithdrawImplementation is ICounterfactualImplementation {
    using SafeERC20 for IERC20;

    /// @notice Sentinel address representing native ETH in withdraw calls.
    address public constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event Withdraw(address indexed token, address indexed to, uint256 amount);

    error Unauthorized();
    error InvalidRecipient();
    error NativeTransferFailed();

    /// @inheritdoc ICounterfactualImplementation
    function execute(bytes calldata params, bytes calldata submitterData) external payable returns (bytes memory) {
        WithdrawParams memory wp = abi.decode(params, (WithdrawParams));
        (address token, address to, uint256 amount) = abi.decode(submitterData, (address, address, uint256));

        if (msg.sender != wp.authorizedCaller) revert Unauthorized();
        if (wp.forcedRecipient != address(0) && to != wp.forcedRecipient) revert InvalidRecipient();

        if (token == NATIVE_ASSET) {
            (bool success, ) = to.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit Withdraw(token, to, amount);

        return "";
    }
}
