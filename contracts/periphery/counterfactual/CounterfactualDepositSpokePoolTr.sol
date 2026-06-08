// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePool } from "./CounterfactualDepositSpokePool.sol";
import { TronTransferLib } from "../../libraries/TronTransferLib.sol";

/**
 * @title CounterfactualDepositSpokePoolTr
 * @notice Tron-specific variant of `CounterfactualDepositSpokePool` for chains where the input token may be
 *         Tron USDT (whose `transfer` returns false on success).
 * @dev Inherits everything from the mainline implementation — including the input-token-agnostic resolution
 *      via the leaf's `inputTokenGetter` selector — and overrides only the `_safeTransfer` hook to use a
 *      balance-delta success check that tolerates Tron USDT's non-standard return value. `forceApprove` is
 *      unaffected (`approve` returns true correctly on Tron USDT).
 *
 *      The EIP-712 domain name is inherited from the mainline implementation. That is safe in the beacon
 *      model: a fee signature commits the `chainId` (via the EIP-712 domain) and the full route — including
 *      the input-token selector — via `routeParamsHash`, and only one SpokePool implementation is deployed
 *      per chain. So a signature cannot cross to another chain or another token; the implementation only
 *      affects transfer semantics, not the economic outcome the signer authorized.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePoolTr is CounterfactualDepositSpokePool {
    /// @dev TRON OVERRIDE: was `IERC20(token).safeTransfer(to, amount)` in the parent.
    ///      `TronTransferLib._safeTransferBalanceCheck` uses a balance-delta success check so it
    ///      tolerates Tron USDT's non-standard `transfer` return value.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}
