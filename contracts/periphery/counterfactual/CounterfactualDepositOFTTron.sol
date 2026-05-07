// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualDepositOFT } from "./CounterfactualDepositOFT.sol";
import { TronTransferLib } from "./TronTransferLib.sol";

/**
 * @title CounterfactualDepositOFTTron
 * @notice Tron-specific variant of `CounterfactualDepositOFT`. Inherits from the mainline
 *         contract and overrides the `_safeTransferERC20` hook to use a balance-delta
 *         success check that tolerates Tron USDT's non-standard `transfer` return value.
 * @dev Tron OFT routes today bridge USDT0 (LayerZero's standard OFT contract), which is a
 *      compliant ERC20 — the bug does not apply. This variant exists for symmetry with the
 *      other Tron counterfactual implementations and to defensively cover any future route
 *      that uses a non-standard ERC20.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositOFTTron is CounterfactualDepositOFT {
    constructor(address _oftSrcPeriphery, uint32 _srcEid) CounterfactualDepositOFT(_oftSrcPeriphery, _srcEid) {} // solhint-disable-line no-empty-blocks

    /// @dev TRON OVERRIDE: was `IERC20(token).safeTransfer(to, amount)` in the parent.
    ///      `TronTransferLib._balanceCheckTransfer` uses a balance-delta success check so it
    ///      tolerates Tron USDT's non-standard `transfer` return value.
    function _safeTransferERC20(address token, address to, uint256 amount) internal override {
        TronTransferLib._balanceCheckTransfer(token, to, amount);
    }
}
