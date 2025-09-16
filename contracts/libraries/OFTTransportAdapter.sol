// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "../interfaces/IOFT.sol";
import { AddressToBytes32 } from "../libraries/AddressConverters.sol";

/**
 * @notice Facilitate bridging tokens via LayerZero's OFT.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools.
 * @custom:security-contact bugs@across.to
 */
contract OFTTransportAdapter {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;

    /** @notice Empty bytes array used for OFT messaging parameters */
    bytes public constant EMPTY_MSG_BYTES = new bytes(0);

    /**
     * @notice Fee cap checked before sending messages to OFTMessenger
     * @dev Conservative (high) cap to not interfere with operations under normal conditions
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable OFT_FEE_CAP;

    /**
     * @notice The destination endpoint id in the OFT messaging protocol.
     * @dev Source https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts.
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable OFT_DST_EID;

    /** @notice Thrown when OFT fee exceeds the configured cap */
    error OftFeeCapExceeded();

    /** @notice Thrown when contract has insufficient balance to pay OFT fees */
    error OftInsufficientBalanceForFee();

    /** @notice Thrown when LayerZero token fee is not zero (only native fees supported) */
    error OftLzFeeNotZero();

    /** @notice Thrown when amount received differs from expected amount */
    error OftIncorrectAmountReceivedLD();

    /** @notice Thrown when amount sent differs from expected amount */
    error OftIncorrectAmountSentLD();

    /**
     * @notice intiailizes the OFTTransportAdapter contract.
     * @param _oftDstEid the endpoint ID that OFT protocol will transfer funds to.
     * @param _feeCap a fee cap we check against before sending a message with value to OFTMessenger as fees.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint32 _oftDstEid, uint256 _feeCap) {
        OFT_DST_EID = _oftDstEid;
        OFT_FEE_CAP = _feeCap;
    }

    /**
     * @notice transfer token to the other dstEid (e.g. chain) via OFT messaging protocol
     * @dev the caller has to provide both _token and _messenger. The caller is responsible for knowing the correct _messenger
     * @param _token token we're sending on current chain.
     * @param _messenger corresponding OFT messenger on current chain.
     * @param _to address to receive a transfer on the destination chain.
     * @param _amount amount to send.
     */
    function _transferViaOFT(IERC20 _token, IOFT _messenger, address _to, uint256 _amount) internal {
        (SendParam memory sendParam, MessagingFee memory fee) = _buildOftTransfer(_messenger, _to, _amount);
        _sendOftTransfer(_token, _messenger, sendParam, fee);
    }

    /**
     * @notice Build OFT send params and quote the native fee.
     * @dev Sets `minAmountLD == amountLD` to disallow silent deductions (e.g. dust removal) by OFT.
     *      The fee is quoted for payment in native token.
     * @param _messenger OFT messenger contract on the current chain for the token being sent.
     * @param _to Destination address on the remote chain.
     * @param _amount Amount of tokens to transfer.
     * @return sendParam The encoded OFT send parameters.
     * @return fee The quoted MessagingFee required for the transfer.
     */
    function _buildOftTransfer(
        IOFT _messenger,
        address _to,
        uint256 _amount
    ) internal view returns (SendParam memory, MessagingFee memory) {
        bytes32 to = _to.toBytes32();

        SendParam memory sendParam = SendParam(
            OFT_DST_EID,
            to,
            /**
             * _amount, _amount here specify `amountLD` and `minAmountLD`. Setting `minAmountLD` equal to `amountLD` protects us
             * from any changes to the sent amount due to internal OFT contract logic, e.g. `_removeDust`. Meaning that if any
             * dust is subtracted, the `.send()` should revert
             */
            _amount,
            _amount,
            /**
             * EMPTY_MSG_BYTES, EMPTY_MSG_BYTES, EMPTY_MSG_BYTES here specify `extraOptions`, `composeMsg` and `oftCmd`.
             * These can be set to empty bytes arrays for the purposes of sending a simple cross-chain transfer.
             */
            EMPTY_MSG_BYTES,
            EMPTY_MSG_BYTES,
            EMPTY_MSG_BYTES
        );

        // `false` in the 2nd param here refers to `bool _payInLzToken`. We will pay in native token, so set to `false`
        MessagingFee memory fee = _messenger.quoteSend(sendParam, false);

        return (sendParam, fee);
    }

    /**
     * @notice Execute an OFT transfer using pre-built params and fee.
     * @dev Verifies fee bounds and equality of sent/received amounts. Pays native fee from this contract.
     * @param _token ERC-20 token to transfer.
     * @param _messenger OFT messenger contract on the current chain for `_token`.
     * @param sendParam Pre-built OFT send parameters.
     * @param fee Quoted MessagingFee to pay for this transfer.
     */
    function _sendOftTransfer(
        IERC20 _token,
        IOFT _messenger,
        SendParam memory sendParam,
        MessagingFee memory fee
    ) internal {
        // Create a stack variable to optimize gas usage on subsequent reads
        uint256 nativeFee = fee.nativeFee;
        if (nativeFee > OFT_FEE_CAP) revert OftFeeCapExceeded();
        if (nativeFee > address(this).balance) revert OftInsufficientBalanceForFee();
        if (fee.lzTokenFee != 0) revert OftLzFeeNotZero();

        // Approve the exact _amount for `_messenger` to spend. Fee will be paid in native token
        uint256 _amount = sendParam.amountLD;
        _token.forceApprove(address(_messenger), _amount);

        (, OFTReceipt memory oftReceipt) = _messenger.send{ value: nativeFee }(sendParam, fee, address(this));

        // The HubPool expects that the amount received by the SpokePool is exactly the sent amount
        if (_amount != oftReceipt.amountReceivedLD) revert OftIncorrectAmountReceivedLD();
        // Also check the amount sent on origin chain to harden security
        if (_amount != oftReceipt.amountSentLD) revert OftIncorrectAmountSentLD();
    }
}
