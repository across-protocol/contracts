// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";

import { Universal_SpokePool } from "./Universal_SpokePool.sol";
import { ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Tron-specific SpokePool variant that handles non-standard ERC20 implementations.
 * @dev Tron USDT's `transfer` always returns false on success, which breaks the return-value
 *      checks in `SafeERC20.safeTransfer` and `SpokePool._noRevertTransfer`. This variant
 *      overrides both base hooks (`_noRevertTransfer` and `_safeTransfer`) with a balance-delta
 *      success check. `transferFrom` is correct on Tron USDT, so paths using `safeTransferFrom`
 *      are unchanged.
 *
 *      Assumes Tether's `basisPointsRate` fee-on-transfer mechanism stays at zero. If it
 *      is ever activated, balance-delta will report failure on successful transfers and
 *      USDT routes on this contract will wedge until disabled operationally.
 * @custom:security-contact bugs@across.to
 */
contract Tron_SpokePool is Universal_SpokePool {
    error TronTransferFailed();

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
        uint256 pre = IERC20Upgradeable(token).balanceOf(to);
        (bool ok, ) = token.call(abi.encodeCall(IERC20Upgradeable.transfer, (to, amount)));
        if (!ok) return false;
        return IERC20Upgradeable(token).balanceOf(to) >= pre + amount;
    }

    /// @dev Revert-on-failure variant of the balance-delta transfer. Replaces the base
    ///      `safeTransfer` call sites (claimRelayerRefund, slow-fill ERC20 path).
    function _safeTransfer(address token, address to, uint256 amount) internal override {
        if (!_noRevertTransfer(token, to, amount)) revert TronTransferFailed();
    }
}
