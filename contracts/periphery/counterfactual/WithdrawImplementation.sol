// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @title WithdrawImplementation
 * @notice Sweeps tokens / native ETH from a counterfactual clone. Typically invoked by the
 *         clone's `admin` via the dispatcher's admin escape; rejects any other caller.
 * @dev Conforms to `ICounterfactualImplementation` so the dispatcher's generic delegate path can
 *      call it. The clone-identity fields (`recipient`, `outputToken`, `destinationChainId`) and
 *      `routeParams` are unused; `submitterData` decodes as `(address token, address to, uint256 amount)`.
 *
 *      Self-protects against accidental inclusion as a policy leaf: `msg.sender == admin` is
 *      enforced inside the impl. If a policy tree mistakenly includes a withdraw leaf, the
 *      proof-path caller (≠ admin) is rejected here even though the dispatcher's merkle check
 *      would otherwise pass.
 * @custom:security-contact bugs@across.to
 */
contract WithdrawImplementation is ICounterfactualImplementation, SafeTransferERC20 {
    event Withdraw(address indexed caller, address indexed token, address indexed to, uint256 amount);

    error NativeTransferFailed();
    error Unauthorized();

    /// @inheritdoc ICounterfactualImplementation
    function execute(
        bytes32 /* recipient */,
        bytes32 /* outputToken */,
        uint256 /* destinationChainId */,
        address admin,
        bytes calldata /* routeParams */,
        bytes calldata submitterData
    ) external payable {
        if (msg.sender != admin) revert Unauthorized();

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
