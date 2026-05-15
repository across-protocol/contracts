// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { Universal_SpokePool } from "./Universal_SpokePool.sol";
import { ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { TronTransferLib } from "../libraries/TronTransferLib.sol";

/**
 * @notice Tron-specific SpokePool variant that handles non-standard ERC20 implementations.
 * @dev Tron USDT's `transfer` always returns false on success, which breaks the return-value
 *      checks in `SafeERC20.safeTransfer` and `SpokePool._noRevertTransfer`. This variant
 *      overrides both base hooks (`_noRevertTransfer` and `_safeTransfer`) to delegate to
 *      `TronTransferLib`, which performs a balance-delta success check. `transferFrom` is
 *      correct on Tron USDT, so paths using `safeTransferFrom` are unchanged.
 *
 *      Assumes Tether's `basisPointsRate` fee-on-transfer mechanism stays at zero. If it
 *      is ever activated, balance-delta will report failure on successful transfers and
 *      USDT routes on this contract will wedge until disabled operationally.
 * @custom:security-contact bugs@across.to
 */
contract Tron_SpokePool is Universal_SpokePool {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        uint256 _adminUpdateBufferSeconds,
        address _helios,
        address _hubPoolStore,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _oftDstEid,
        uint256 _oftFeeCap
    )
        Universal_SpokePool(
            _adminUpdateBufferSeconds,
            _helios,
            _hubPoolStore,
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger,
            _oftDstEid,
            _oftFeeCap
        )
    {} // solhint-disable-line no-empty-blocks

    /// @dev Replaces base implementation's return-value-based success detection with a
    ///      balance-delta check. Required because Tron USDT's `transfer` returns false
    ///      even on successful transfers.
    function _noRevertTransfer(address token, address to, uint256 amount) internal override returns (bool) {
        (bool callOk, bool balanceOk) = TronTransferLib._balanceDeltaTransfer(token, to, amount);
        return callOk && balanceOk;
    }

    /// @dev Revert-on-failure variant; reverts with `TronTransferCallReverted` or
    ///      `TronTransferBalanceMismatch` so callers can distinguish failure modes.
    ///      Replaces the base `safeTransfer` call sites (claimRelayerRefund, slow-fill ERC20 path).
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        TronTransferLib._safeTransferBalanceCheck(token, to, amount);
    }
}
