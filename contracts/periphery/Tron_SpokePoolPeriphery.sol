// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { SpokePoolPeriphery, SwapProxy } from "./SpokePoolPeriphery.sol";
import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { TronTransferLib } from "../libraries/TronTransferLib.sol";

/**
 * @title Tron_SwapProxy
 * @notice Tron variant of `SwapProxy` for tokens like Tron USDT (whose `transfer` returns false on
 *         success). Overrides only the `_safeTransfer` hook to use a balance-delta success check;
 *         `forceApprove` and permit2 paths are unaffected.
 * @custom:security-contact bugs@across.to
 */
contract Tron_SwapProxy is SwapProxy {
    constructor(address _permit2) SwapProxy(_permit2) {} // solhint-disable-line no-empty-blocks

    /// @dev TRON OVERRIDE of `_safeTransfer`: a balance-delta success check that tolerates Tron USDT's
    ///      non-standard `transfer` return value.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}

/**
 * @title Tron_SpokePoolPeriphery
 * @notice Tron variant of `SpokePoolPeriphery` for tokens like Tron USDT (whose `transfer` returns
 *         false on success).
 * @dev Inherits the mainline impl and overrides only `_safeTransfer` (swap-token handoff and
 *      submission-fee payout) plus `_deploySwapProxy` (so the constructor-deployed swap proxy is a
 *      `Tron_SwapProxy`). `transferFrom` is correct on Tron USDT, so `safeTransferFrom` pull paths and
 *      `forceApprove` are unchanged. The mainline EIP-712 name is inherited, which is safe: the domain
 *      separator commits to `chainId` and `verifyingContract`, so signatures cannot cross chains or
 *      deployments, and the variant changes only transfer semantics, not the signed outcome.
 * @custom:security-contact bugs@across.to
 */
contract Tron_SpokePoolPeriphery is SpokePoolPeriphery {
    // solhint-disable-next-line no-empty-blocks
    constructor(IPermit2 _permit2, address _multicall3) SpokePoolPeriphery(_permit2, _multicall3) {}

    /// @dev Deploys the Tron variant of the swap proxy so its exchange/output transfers also tolerate
    ///      Tron USDT's non-standard `transfer` return value.
    function _deploySwapProxy(address _permit2) internal override returns (SwapProxy) {
        return new Tron_SwapProxy(_permit2);
    }

    /// @dev TRON OVERRIDE of `_safeTransfer`: a balance-delta success check that tolerates Tron USDT's
    ///      non-standard `transfer` return value.
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}
