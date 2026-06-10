// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import { MulticallHandler } from "./MulticallHandler.sol";
import { TronTransferLib } from "../libraries/TronTransferLib.sol";

/**
 * @title TronMulticallHandler
 * @notice Tron-specific variant of `MulticallHandler` for tokens such as Tron USDT whose
 *         `transfer` returns false even when it moves balances successfully.
 * @dev Inherits all multicall behavior from the mainline handler and overrides only the
 *      ERC20 drain transfer hook to use a balance-delta success check.
 * @custom:security-contact bugs@across.to
 */
contract TronMulticallHandler is MulticallHandler {
    /// @dev TRON OVERRIDE: was `IERC20(token).safeTransfer(to, amount)` in the parent.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}
