// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositSpokePool } from "./CounterfactualDepositSpokePool.sol";
import { TronTransferLib } from "../../libraries/TronTransferLib.sol";

/**
 * @title CounterfactualDepositSpokePoolTr
 * @notice Tron-specific SpokePool counterfactual deposit whose input token is Tron USDT (whose `transfer`
 *         returns false on success), resolved from `beacon.usdt()`.
 * @dev Fixes the input token to USDT and overrides the `_safeTransfer` hook to use a balance-delta success
 *      check that tolerates Tron USDT's non-standard return value. `forceApprove` is unaffected — `approve`
 *      returns true correctly on Tron USDT.
 *
 *      The EIP-712 domain name is distinct from the mainline variants so a fee signature is bound to this
 *      (USDT, Tron) variant; cross-clone replay is additionally prevented by the `verifyingContract` field.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePoolTr is CounterfactualDepositSpokePool {
    constructor() CounterfactualDepositSpokePool("CounterfactualDepositSpokePoolUsdtTr") {} // solhint-disable-line no-empty-blocks

    function _inputToken() internal view override returns (address) {
        return _beacon().usdt();
    }

    /// @dev TRON OVERRIDE: was `IERC20(token).safeTransfer(to, amount)` in the parent.
    ///      `TronTransferLib._safeTransferBalanceCheck` uses a balance-delta success check so it
    ///      tolerates Tron USDT's non-standard `transfer` return value.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}
