// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePool } from "./CounterfactualDepositSpokePool.sol";
import { TronTransferLib } from "../../libraries/TronTransferLib.sol";

/**
 * @title CounterfactualDepositSpokePoolTr
 * @notice Tron variant of `CounterfactualDepositSpokePool` for input tokens like Tron USDT (whose
 *         `transfer` returns false on success).
 * @dev Inherits the mainline impl (including input-token-agnostic resolution) and overrides only
 *      `_safeTransfer` to use a balance-delta success check tolerating Tron USDT's non-standard return;
 *      `forceApprove` is unaffected. The mainline EIP-712 name is inherited, which is safe: a fee signature
 *      commits `chainId` and the full route (incl. token selector) via `routeParamsHash`, and only one
 *      SpokePool impl is deployed per chain — so it can't cross chains or tokens, and the variant changes
 *      only transfer semantics, not the signed outcome.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePoolTr is CounterfactualDepositSpokePool {
    /// @dev TRON OVERRIDE of `_safeTransfer`: a balance-delta success check that tolerates Tron USDT's
    ///      non-standard `transfer` return value.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}
