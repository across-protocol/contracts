// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";

/**
 * @notice Withdrawal parameters committed to in the merkle leaf.
 * @param admin Admin address authorized to execute this withdrawal leaf.
 * @param user User address authorized to execute this withdrawal leaf.
 */
struct WithdrawParams {
    address admin;
    address user;
}

/**
 * @title WithdrawImplementation
 * @notice Handles token/ETH withdrawals as a merkle leaf implementation.
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. `address(this)` is the clone
 *      and `msg.sender` is the original caller.
 */
contract WithdrawImplementation is ICounterfactualImplementation {
    using SafeERC20 for IERC20;

    event Withdraw(address indexed token, address indexed to, uint256 amount);

    error Unauthorized();
    error NativeTransferFailed();

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Recovery/sweep mechanism — no bridging. `params` is ABI-encoded as `WithdrawParams` (admin, user);
     *      `submitterData` as `(address token, address to, uint256 amount)`.
     *      Reverts: `Unauthorized` (caller is not admin or user), `NativeTransferFailed`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        WithdrawParams memory wp = abi.decode(params, (WithdrawParams));
        (address token, address to, uint256 amount) = abi.decode(submitterData, (address, address, uint256));

        if (msg.sender != wp.admin && msg.sender != wp.user) revert Unauthorized();

        if (token == NATIVE_ASSET) {
            (bool success, ) = to.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit Withdraw(token, to, amount);
    }
}
