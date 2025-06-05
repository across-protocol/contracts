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
    uint256 nativeFee;
    uint256 lzFee;

    constructor(
        address _token,
        uint256 _nativeFee,
        uint256 _lzFee
    ) {
        token = _token;
        nativeFee = _nativeFee;
        lzFee = _lzFee;
    }

    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, lzFee);
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory) {
        return (MessagingReceipt(0, 0, MessagingFee(0, 0)), OFTReceipt(_sendParam.amountLD, _sendParam.amountLD));
    }
}
