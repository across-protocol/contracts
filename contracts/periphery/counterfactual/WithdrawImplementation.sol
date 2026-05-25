// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET } from "./CounterfactualConstants.sol";
import { SafeTransferERC20 } from "../../libraries/SafeTransferERC20.sol";

/**
 * @title WithdrawImplementation
 * @notice Sweeps tokens / native ETH from a counterfactual clone to its bound `userAddress`. The
 *         recipient is fixed by clone identity, not chosen at execute time. Callers are restricted
 *         to either the immutable `admin` (typically an `AdminWithdrawManager` that gates calls
 *         behind its own auth) or the clone's `userAddress` (so users can always withdraw their
 *         own funds, independent of policy state or manager availability).
 * @dev Conforms to `ICounterfactualImplementation` so the dispatcher's generic delegate path can
 *      call it. The clone-identity fields (`recipient`, `outputToken`, `destinationChainId`) and
 *      `routeParams` are unused; `submitterData` decodes as `(address token, uint256 amount)` —
 *      the destination is always `userAddress`.
 *
 *      Trust model: the `AdminWithdrawManager` (or whatever `admin` points to) authorizes _when_
 *      and _how much_, never _where_. A compromised manager / signer / direct-withdrawer can
 *      force withdrawals to the user's address but cannot redirect them.
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

        (address token, uint256 amount) = abi.decode(submitterData, (address, uint256));

        if (token == NATIVE_ASSET) {
            (bool success, ) = userAddress.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            _safeTransfer(token, userAddress, amount);
        }

        emit Withdraw(msg.sender, token, userAddress, amount);
    }
}
