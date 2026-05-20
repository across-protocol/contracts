// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { CloneArgs } from "./CounterfactualCloneArgs.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @title WithdrawImplementation
 * @notice Sweeps tokens / native ETH from a counterfactual clone. Invoked via the dispatcher's
 *         structural withdraw escape, which already enforces `msg.sender == cloneArgs.withdrawUser`
 *         and bypasses the merkle proof — so this contract performs no authorization of its own.
 * @dev Deployed deterministically with no constructor args; the dispatcher's `WITHDRAW_IMPL` immutable
 *      pins the canonical address.
 * @custom:security-contact bugs@across.to
 */
contract WithdrawImplementation is ICounterfactualImplementation, SafeTransferERC20 {
    event Withdraw(address indexed caller, address indexed token, address indexed to, uint256 amount);

    error NativeTransferFailed();

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev `cloneArgs` and `params` are unused; `submitterData` decodes as `(address token, address to, uint256 amount)`.
     */
    function execute(
        CloneArgs calldata /* cloneArgs */,
        bytes calldata /* params */,
        bytes calldata submitterData
    ) external payable {
        (address token, address to, uint256 amount) = abi.decode(submitterData, (address, address, uint256));

        if (token == NATIVE_ASSET) {
            (bool success, ) = to.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            _safeTransfer(token, to, amount);
        }

        emit Withdraw(msg.sender, token, to, amount);
    }
}
