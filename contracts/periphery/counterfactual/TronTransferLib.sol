// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Balance-delta ERC20 transfer for tokens whose `transfer` returns non-standard
 *         values. Specifically targets Tron USDT, which returns false even on success.
 * @dev Reverts with `TronTransferFailed` if the underlying call reverts or if the
 *      recipient's balance does not increase by at least `amount`. Assumes no fee-on-transfer.
 */
library TronTransferLib {
    error TronTransferFailed();

    function _balanceCheckTransfer(address token, address to, uint256 amount) internal {
        uint256 pre = IERC20(token).balanceOf(to);
        (bool ok, ) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) revert TronTransferFailed();
        if (IERC20(token).balanceOf(to) < pre + amount) revert TronTransferFailed();
    }
}
