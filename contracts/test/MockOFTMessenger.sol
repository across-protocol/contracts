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

    constructor(address _token) {
        token = _token;
    }

    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view returns (MessagingFee memory) {
        return MessagingFee(0, 0);
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory) {
        return (MessagingReceipt(0, 0, MessagingFee(0, 0)), OFTReceipt(_sendParam.amountLD, _sendParam.amountLD));
    }
}
