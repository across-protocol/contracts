// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @title WithdrawImplementation
 * @notice Sweeps tokens / native ETH from a counterfactual clone. Typically invoked by the
 *         clone's `admin` via the dispatcher's admin escape; can also be a policy-authorized
 *         route like any other impl, though there's normally no reason to put a withdraw in the
 *         tree. Performs no authorization of its own — the dispatcher gates access.
 * @dev Conforms to `ICounterfactualImplementation` so the dispatcher's generic delegate path can
 *      call it. The clone-identity fields (`recipient`, `outputToken`, `destinationChainId`) and
 *      `routeParams` are unused; `submitterData` decodes as `(address token, address to, uint256 amount)`.
 * @custom:security-contact bugs@across.to
 */
contract WithdrawImplementation is ICounterfactualImplementation, SafeTransferERC20 {
    event Withdraw(address indexed caller, address indexed token, address indexed to, uint256 amount);

    error NativeTransferFailed();

    /// @inheritdoc ICounterfactualImplementation
    function execute(
        bytes32 /* recipient */,
        bytes32 /* outputToken */,
        uint256 /* destinationChainId */,
        bytes calldata /* routeParams */,
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
