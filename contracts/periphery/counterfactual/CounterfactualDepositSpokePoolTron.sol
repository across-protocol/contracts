// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePool } from "./CounterfactualDepositSpokePool.sol";
import { TronTransferLib } from "./TronTransferLib.sol";

/**
 * @title CounterfactualDepositSpokePoolTron
 * @notice Tron-specific variant of `CounterfactualDepositSpokePool` for chains where the
 *         input token may be Tron USDT (whose `transfer` returns false on success).
 * @dev Inherits everything from the mainline implementation and overrides the
 *      `_safeTransferErc20` hook to use a balance-delta success check that tolerates
 *      Tron USDT's non-standard return value. `forceApprove` is unaffected — `approve`
 *      returns true correctly on Tron USDT.
 *
 *      The EIP-712 domain name is inherited from the parent (`CounterfactualDepositSpokePool`).
 *      Cross-implementation signature replay is already prevented by the `verifyingContract`
 *      field of the EIP-712 domain: each clone's address is derived via CREATE2 from its
 *      implementation address, so a signature for a mainline clone does not verify against
 *      a Tron-variant clone.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePoolTron is CounterfactualDepositSpokePool {
    constructor(
        address _spokePool,
        address _signer,
        address _wrappedNativeToken
    ) CounterfactualDepositSpokePool(_spokePool, _signer, _wrappedNativeToken) {} // solhint-disable-line no-empty-blocks

    /// @dev TRON OVERRIDE: was `IERC20(token).safeTransfer(to, amount)` in the parent.
    ///      `TronTransferLib.balanceCheckTransfer` uses a balance-delta success check so it
    ///      tolerates Tron USDT's non-standard `transfer` return value.
    function _safeTransferErc20(address token, address to, uint256 amount) internal override {
        TronTransferLib.balanceCheckTransfer(token, to, amount);
    }
}
