// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @title WithdrawImplementation
 * @notice Sweeps tokens / native ETH from a counterfactual clone. Callers are restricted to
 *         either the immutable `admin` (typically an `AdminWithdrawManager` that gates calls
 *         behind its own auth) or the clone's `userAddress` (so users can always withdraw their
 *         own funds, independent of policy state or manager availability).
 * @dev Conforms to `ICounterfactualImplementation` so the dispatcher's generic delegate path can
 *      call it. The clone-identity fields (`recipient`, `outputToken`, `destinationChainId`) and
 *      `routeParams` are unused; `submitterData` decodes as `(address token, uint256 amount,
 *      address to)`.
 *
 *      When called by the clone's `userAddress`, the `to` field is ignored and funds are always
 *      sent to `userAddress`. When called by the `admin`, the `to` address is used as-is —
 *      the admin (typically `AdminWithdrawManager`) is responsible for enforcing its own
 *      recipient restrictions per withdraw path.
 * @custom:security-contact bugs@across.to
 */
contract WithdrawImplementation is ICounterfactualImplementation, SafeTransferERC20 {
    event Withdraw(address indexed caller, address indexed token, address indexed to, uint256 amount);

    error NativeTransferFailed();
    error Unauthorized();

    /// @notice Address authorized to trigger withdrawals in addition to the clone's user.
    ///         Typically the canonical `AdminWithdrawManager` for the deployment.
    address public immutable admin;

    constructor(address _admin) {
        admin = _admin;
    }

    /// @inheritdoc ICounterfactualImplementation
    function execute(
        bytes32 /* recipient */,
        bytes32 /* outputToken */,
        uint256 /* destinationChainId */,
        address userAddress,
        bytes calldata /* routeParams */,
        bytes calldata submitterData
    ) external payable {
        if (msg.sender != admin && msg.sender != userAddress) revert Unauthorized();

        (address token, uint256 amount, address to) = abi.decode(submitterData, (address, uint256, address));

        // User always withdraws to themselves regardless of the supplied `to`.
        if (msg.sender == userAddress) to = userAddress;

        if (token == NATIVE_ASSET) {
            (bool success, ) = to.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            _safeTransfer(token, to, amount);
        }

        emit Withdraw(msg.sender, token, to, amount);
    }
}
