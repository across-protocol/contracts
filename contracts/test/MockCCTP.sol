// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../libraries/CircleCCTPAdapter.sol";
import { IMessageTransmitter } from "../external/interfaces/CCTPInterfaces.sol";

contract MockCCTPMinter is ITokenMinter {
    uint256 private _burnLimit = type(uint256).max;

    function setBurnLimit(uint256 limit) external {
        _burnLimit = limit;
    }

    function burnLimitsPerMessage(address) external view returns (uint256) {
        return _burnLimit;
    }
}

contract MockCCTPMessenger is ITokenMessenger {
    ITokenMinter private minter;
    uint256 public depositForBurnCallCount;

    // Event for vm.expectEmit compatibility
    event DepositForBurnCalled(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken);

    // Last call parameters (similar to smock's calledWith behavior)
    struct DepositForBurnCall {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
    }
    DepositForBurnCall public lastDepositForBurnCall;

    constructor(ITokenMinter _minter) {
        minter = _minter;
    }

    function depositForBurn(
        uint256 _amount,
        uint32 _destinationDomain,
        bytes32 _mintRecipient,
        address _burnToken
    ) external returns (uint64 _nonce) {
        depositForBurnCallCount++;
        lastDepositForBurnCall = DepositForBurnCall(_amount, _destinationDomain, _mintRecipient, _burnToken);
        emit DepositForBurnCalled(_amount, _destinationDomain, _mintRecipient, _burnToken);
        return 0;
    }

    function localMinter() external view returns (ITokenMinter) {
        return minter;
    }
}

contract MockCCTPMessageTransmitter is IMessageTransmitter {
    uint256 public sendMessageCallCount;

    // Event for vm.expectEmit compatibility
    event SendMessageCalled(uint32 destinationDomain, bytes32 recipient, bytes messageBody);

    // Last call parameters (similar to smock's calledWith behavior)
    struct SendMessageCall {
        uint32 destinationDomain;
        bytes32 recipient;
        bytes messageBody;
    }
    SendMessageCall public lastSendMessageCall;

    function sendMessage(
        uint32 _destinationDomain,
        bytes32 _recipient,
        bytes calldata _messageBody
    ) external returns (uint64) {
        sendMessageCallCount++;
        lastSendMessageCall = SendMessageCall(_destinationDomain, _recipient, _messageBody);
        emit SendMessageCalled(_destinationDomain, _recipient, _messageBody);
        return 0;
    }
}
