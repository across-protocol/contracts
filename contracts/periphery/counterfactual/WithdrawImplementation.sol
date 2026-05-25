// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @title WithdrawImplementation
 * @notice Sweeps tokens / native ETH from a counterfactual clone to a caller-specified recipient.
 *         Authorized callers are either the impl's immutable `admin` (typically an
 *         `AdminWithdrawManager` that gates calls behind its own auth) or the clone's
 *         `userAddress` (so users can always withdraw their own funds, independent of policy
 *         state or manager availability). The recipient is supplied by the caller via
 *         `submitterData`; the manager's `signedWithdraw` path forces the recipient to the
 *         clone's `userAddress` so a compromised `signer` cannot redirect funds.
 * @dev Conforms to `ICounterfactualImplementation` so the dispatcher's generic delegate path can
 *      call it. The clone-identity bridge fields (`recipient`, `outputToken`,
 *      `destinationChainId`) and `routeParams` are unused; `submitterData` decodes as
 *      `(address token, address recipient, uint256 amount)`.
 *
 *      Trust model: the immutable `admin` (e.g. `AdminWithdrawManager`) decides what level of
 *      flexibility to grant each of its own roles — the manager's `directWithdrawer` is trusted
 *      to choose recipient, while its `signer` is not (recipient pinned to `userAddress`). A
 *      compromised `signer` can force a withdrawal to the user's address but cannot redirect it.
 *      A compromised `directWithdrawer` retains full authority.
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

        (address token, address recipient, uint256 amount) = abi.decode(submitterData, (address, address, uint256));

        if (token == NATIVE_ASSET) {
            (bool success, ) = recipient.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            _safeTransfer(token, recipient, amount);
        }

        emit Withdraw(msg.sender, token, recipient, amount);
    }
}
