// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { WithdrawImplementation } from "./WithdrawImplementation.sol";
import { TronTransferLib } from "./TronTransferLib.sol";

/**
 * @title WithdrawImplementationTron
 * @notice Tron-specific variant of `WithdrawImplementation`. Inherits from the mainline
 *         contract and overrides the `_safeTransfer` hook to use a balance-delta
 *         success check that tolerates Tron USDT's non-standard `transfer` return value.
 *         Native-asset withdrawals are unchanged.
 * @custom:security-contact bugs@across.to
 */
contract WithdrawImplementationTron is WithdrawImplementation {
    /// @dev TRON OVERRIDE: was `IERC20(token).safeTransfer(to, amount)` in the parent.
    ///      `TronTransferLib._balanceCheckTransfer` uses a balance-delta success check so it
    ///      tolerates Tron USDT's non-standard `transfer` return value.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._balanceCheckTransfer(token, to, amount);
    }
}
