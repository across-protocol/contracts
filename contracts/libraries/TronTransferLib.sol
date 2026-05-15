// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Balance-delta ERC20 transfer for tokens whose `transfer` returns non-standard
 *         values. Specifically targets Tron USDT, which returns false even on success.
 * @dev Two-error model: `_safeTransferBalanceCheck` reverts with `TronTransferCallReverted`
 *      if the underlying call reverts, or `TronTransferBalanceMismatch` if the call returns
 *      but the recipient's balance does not increase by exactly `amount`. `_balanceDeltaTransfer`
 *      is the bool-pair primitive both wrappers (revert / no-revert) share — callers needing a
 *      collapsed bool can AND the two flags. Assumes no fee-on-transfer.
 *
 *      IERC20 and IERC20Upgradeable produce bytewise-identical calldata for
 *      `transfer(address,uint256)` and `balanceOf(address)`, so this library is safe to call
 *      from contracts using either OZ variant.
 */
library TronTransferLib {
    error TronTransferCallReverted();
    error TronTransferBalanceMismatch();

    /// @dev Returns (callOk, balanceOk). callOk=false means the low-level call reverted;
    ///      balanceOk=false means the call returned but balance did not change by exactly `amount`.
    ///      When callOk=false, balanceOk is also false (no balance check performed).
    function _balanceDeltaTransfer(
        address token,
        address to,
        uint256 amount
    ) internal returns (bool callOk, bool balanceOk) {
        uint256 pre = IERC20(token).balanceOf(to);
        (callOk, ) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!callOk) return (false, false);
        balanceOk = IERC20(token).balanceOf(to) == pre + amount;
    }

    function _safeTransferBalanceCheck(address token, address to, uint256 amount) internal {
        (bool callOk, bool balanceOk) = _balanceDeltaTransfer(token, to, amount);
        if (!callOk) revert TronTransferCallReverted();
        if (!balanceOk) revert TronTransferBalanceMismatch();
    }
}
