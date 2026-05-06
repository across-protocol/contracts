// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Mixin exposing a virtual `_safeTransferErc20` hook. Default implementation uses
 *         OZ `SafeERC20.safeTransfer`. Inheritors may override to swap in alternative
 *         ERC20 transfer semantics.
 */
abstract contract SafeTransferErc20 {
    using SafeERC20 for IERC20;

    function _safeTransferErc20(address token, address to, uint256 amount) internal virtual {
        IERC20(token).safeTransfer(to, amount);
    }
}
