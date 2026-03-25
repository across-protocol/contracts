// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMessageService, ITokenBridge } from "../external/interfaces/LineaInterfaces.sol";

/**
 * @notice Mock implementation of Linea's L2 Message Service.
 * @dev Used for testing Linea_SpokePool functionality.
 */
contract MockL2MessageService is IMessageService {
    address private _sender;
    uint256 private _minimumFeeInWei;

    // Track sendMessage calls
    uint256 public sendMessageCallCount;

    event SendMessageCalled(address indexed to, uint256 fee, bytes calldata_);

    struct SendMessageCall {
        address to;
        uint256 fee;
        bytes calldata_;
        uint256 value;
    }
    SendMessageCall public lastSendMessageCall;

    function setSender(address sender_) external {
        _sender = sender_;
    }

    function setMinimumFeeInWei(uint256 fee) external {
        _minimumFeeInWei = fee;
    }

    function sendMessage(address _to, uint256 _fee, bytes calldata _calldata) external payable override {
        sendMessageCallCount++;
        lastSendMessageCall = SendMessageCall({ to: _to, fee: _fee, calldata_: _calldata, value: msg.value });
        emit SendMessageCalled(_to, _fee, _calldata);
    }

    function sender() external view override returns (address) {
        return _sender;
    }

    function minimumFeeInWei() external view override returns (uint256) {
        return _minimumFeeInWei;
    }

    // Allow receiving ETH
    receive() external payable {}
}

/**
 * @notice Mock implementation of Linea's L2 Token Bridge.
 * @dev Used for testing Linea_SpokePool functionality.
 */
contract MockL2TokenBridge is ITokenBridge {
    uint256 public bridgeTokenCallCount;

    event BridgeTokenCalled(address indexed token, uint256 amount, address indexed recipient, uint256 value);

    struct BridgeTokenCall {
        address token;
        uint256 amount;
        address recipient;
        uint256 value;
    }
    BridgeTokenCall public lastBridgeTokenCall;

    function bridgeToken(address _token, uint256 _amount, address _recipient) external payable override {
        bridgeTokenCallCount++;
        lastBridgeTokenCall = BridgeTokenCall({
            token: _token,
            amount: _amount,
            recipient: _recipient,
            value: msg.value
        });
        emit BridgeTokenCalled(_token, _amount, _recipient, msg.value);
    }

    // Allow receiving ETH
    receive() external payable {}
}
