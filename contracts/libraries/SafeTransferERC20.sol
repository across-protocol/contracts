// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Mixin exposing a virtual `_safeTransfer` hook. Default implementation uses
 *         OZ `SafeERC20.safeTransfer`. Inheritors may override to swap in alternative
 *         ERC20 transfer semantics.
 * @dev Intentionally uses OZ v5, even in inheritors that otherwise use OZ v4: failed transfers
 *      revert with the v5 custom error `SafeERC20FailedOperation(address)`, not the v4 string
 *      "SafeERC20: ERC20 operation did not succeed".
 */
abstract contract SafeTransferERC20 {
    // This mixin is the only place in the codebase permitted to call `IERC20.safeTransfer`
    // directly. Inheriting contracts restrict their own `using` directives to exclude
    // `safeTransfer` so all transfer call sites are forced through this overridable hook.
    using { SafeERC20.safeTransfer } for IERC20;

    function _safeTransfer(address token, address to, uint256 amount) internal virtual {
        IERC20(token).safeTransfer(to, amount);
    }
}
