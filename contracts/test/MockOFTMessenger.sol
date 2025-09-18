// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../interfaces/IOFT.sol";

/**
 * @notice Facilitate bridging tokens via LayerZero's OFT.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools.
 * @custom:security-contact bugs@across.to
 */
contract MockOFTMessenger is IOFT {
    address public token;
    uint256 public nativeFee;
    uint256 public lzFee;
    uint256 public amountSentLDToReturn;
    uint256 public amountReceivedLDToReturn;
    bool public useCustomReceipt;

    constructor(address _token) {
        token = _token;
    }

    function quoteSend(
        SendParam calldata, /*_sendParam*/
        bool /*_payInLzToken*/
    ) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, lzFee);
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata, /*_fee*/
        address /*_refundAddress*/
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory) {
        if (useCustomReceipt) {
            return (
                MessagingReceipt(0, 0, MessagingFee(0, 0)),
                OFTReceipt(amountSentLDToReturn, amountReceivedLDToReturn)
            );
        }
        return (MessagingReceipt(0, 0, MessagingFee(0, 0)), OFTReceipt(_sendParam.amountLD, _sendParam.amountLD));
    }

    function setLDAmountsToReturn(uint256 _amountSentLD, uint256 _amountReceivedLD) external {
        amountSentLDToReturn = _amountSentLD;
        amountReceivedLDToReturn = _amountReceivedLD;
        useCustomReceipt = true;
    }

    function resetReceipt() external {
        useCustomReceipt = false;
    }

    function setFeesToReturn(uint256 _nativeFee, uint256 _lzFee) external {
        nativeFee = _nativeFee;
        lzFee = _lzFee;
    }
}
