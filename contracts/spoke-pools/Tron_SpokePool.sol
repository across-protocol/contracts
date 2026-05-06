// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";

import { Universal_SpokePool } from "./Universal_SpokePool.sol";
import { ITokenMessenger } from "../external/interfaces/CCTPInterfaces.sol";
import { AcrossMessageHandler } from "../interfaces/SpokePoolMessageHandler.sol";
import { AddressLibUpgradeable } from "../upgradeable/AddressLibUpgradeable.sol";
import { Bytes32ToAddress } from "../libraries/AddressConverters.sol";

/**
 * @notice Tron-specific SpokePool variant that handles non-standard ERC20 implementations.
 * @dev Tron USDT's `transfer` always returns false on success, which breaks the return-value
 *      checks in `SafeERC20.safeTransfer` and `SpokePool._noRevertTransfer`. This variant
 *      replaces those checks with a balance-delta check at the three call sites in base
 *      SpokePool that could target Tron USDT. `transferFrom` is correct on Tron USDT, so
 *      paths using `safeTransferFrom` are unchanged.
 *
 *      Assumes Tether's `basisPointsRate` fee-on-transfer mechanism stays at zero. If it
 *      is ever activated, balance-delta will report failure on successful transfers and
 *      USDT routes on this contract will wedge until disabled operationally.
 * @custom:security-contact bugs@across.to
 */
contract Tron_SpokePool is Universal_SpokePool {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Bytes32ToAddress for bytes32;

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

    /// @dev Revert-on-failure wrapper around `_noRevertTransfer`. Used at call sites
    ///      where base SpokePool would have called `IERC20.safeTransfer`.
    function _tronSafeTransfer(address token, address to, uint256 amount) internal {
        if (!_noRevertTransfer(token, to, amount)) revert TronTransferFailed();
    }

    /**
     * @notice Enables a relayer to claim outstanding repayments. Should virtually never be used, unless for some reason
     * relayer repayment transfer fails for reasons such as token transfer reverts due to blacklisting. In this case,
     * the relayer can still call this method and claim the tokens to a new address.
     * @param l2TokenAddress Address of the L2 token to claim refunds for.
     * @param refundAddress Address to send the refund to.
     */
    function claimRelayerRefund(bytes32 l2TokenAddress, bytes32 refundAddress) external override {
        uint256 refund = relayerRefund[l2TokenAddress.toAddress()][msg.sender];
        if (refund == 0) revert NoRelayerRefundToClaim();
        relayerRefund[l2TokenAddress.toAddress()][msg.sender] = 0;
        // TRON OVERRIDE: was `IERC20Upgradeable(l2TokenAddress.toAddress()).safeTransfer(refundAddress.toAddress(), refund)`.
        // `_tronSafeTransfer` uses a balance-delta success check so it tolerates Tron USDT's
        // non-standard `transfer` return value.
        _tronSafeTransfer(l2TokenAddress.toAddress(), refundAddress.toAddress(), refund);

        emit ClaimedRelayerRefund(l2TokenAddress, refundAddress, refund, msg.sender);
    }

    /// @dev Copy of base `_transferTokensToRecipient` with the slow-fill ERC20 `safeTransfer`
    ///      replaced by `_tronSafeTransfer`. That is the only path in base that calls
    ///      `safeTransfer` on a token that could be Tron USDT — `safeTransferFrom` paths
    ///      and the wrapped-native unwrap path are unaffected.
    function _transferTokensToRecipient(
        V3RelayExecutionParams memory relayExecution,
        V3RelayData memory relayData,
        bool isSlowFill
    ) internal override {
        address outputToken = relayData.outputToken.toAddress();
        uint256 amountToSend = relayExecution.updatedOutputAmount;
        address recipientToSend = relayExecution.updatedRecipient.toAddress();

        // If relay token is wrappedNativeToken then unwrap and send native token.
        if (outputToken == address(wrappedNativeToken)) {
            // Note: useContractFunds is True if we want to send funds to the recipient directly out of this contract,
            // otherwise we expect the caller to send funds to the recipient. If useContractFunds is True and the
            // recipient wants wrappedNativeToken, then we can assume that wrappedNativeToken is already in the
            // contract, otherwise we'll need the user to send wrappedNativeToken to this contract. Regardless, we'll
            // need to unwrap it to native token before sending to the user.
            if (!isSlowFill) IERC20Upgradeable(outputToken).safeTransferFrom(msg.sender, address(this), amountToSend);
            _unwrapwrappedNativeTokenTo(payable(recipientToSend), amountToSend);
            // Else, this is a normal ERC20 token. Send to recipient.
        } else {
            // Note: Similar to note above, send token directly from the contract to the user in the slow relay case.
            if (!isSlowFill)
                IERC20Upgradeable(outputToken).safeTransferFrom(msg.sender, recipientToSend, amountToSend);
                // TRON OVERRIDE: was `IERC20Upgradeable(outputToken).safeTransfer(recipientToSend, amountToSend)`.
                // `_tronSafeTransfer` uses a balance-delta success check so it tolerates Tron USDT's
                // non-standard `transfer` return value.
            else _tronSafeTransfer(outputToken, recipientToSend, amountToSend);
        }

        bytes memory updatedMessage = relayExecution.updatedMessage;
        if (updatedMessage.length > 0 && AddressLibUpgradeable.isContract(recipientToSend)) {
            AcrossMessageHandler(recipientToSend).handleV3AcrossMessage(
                outputToken,
                amountToSend,
                msg.sender,
                updatedMessage
            );
        }
    }
}
