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

    // Store all calls for multi-call verification (smock's atCall behavior)
    DepositForBurnCall[] public depositForBurnCalls;

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
        depositForBurnCalls.push(lastDepositForBurnCall);
        emit DepositForBurnCalled(_amount, _destinationDomain, _mintRecipient, _burnToken);
        return 0;
    }

    function localMinter() external view returns (ITokenMinter) {
        return minter;
    }

    /**
     * @notice Get a specific depositForBurn call by index (smock's atCall behavior).
     */
    function getDepositForBurnCall(
        uint256 index
    ) external view returns (uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken) {
        DepositForBurnCall memory call = depositForBurnCalls[index];
        return (call.amount, call.destinationDomain, call.mintRecipient, call.burnToken);
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

/**
 * @notice Mock CCTP V2 TokenMessenger that implements the V2 depositForBurn interface.
 * @dev V2 has a different depositForBurn signature with additional parameters (destinationCaller, maxFee, minFinalityThreshold).
 *      The V2 contract is detected by the CircleCCTPAdapter via the feeRecipient() function.
 */
contract MockCCTPMessengerV2 {
    ITokenMinter private minter;
    address private _feeRecipient;
    uint256 public depositForBurnCallCount;

    // Event for vm.expectEmit compatibility
    event DepositForBurnCalled(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    // Last call parameters (similar to smock's calledWith behavior)
    struct DepositForBurnV2Call {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }
    DepositForBurnV2Call public lastDepositForBurnCall;

    // Store all calls for multi-call verification
    DepositForBurnV2Call[] public depositForBurnCalls;

    constructor(ITokenMinter _minter, address feeRecipient_) {
        minter = _minter;
        _feeRecipient = feeRecipient_;
    }

    /**
     * @notice CCTP V2 depositForBurn function.
     */
    function depositForBurn(
        uint256 _amount,
        uint32 _destinationDomain,
        bytes32 _mintRecipient,
        address _burnToken,
        bytes32 _destinationCaller,
        uint256 _maxFee,
        uint32 _minFinalityThreshold
    ) external {
        depositForBurnCallCount++;
        lastDepositForBurnCall = DepositForBurnV2Call(
            _amount,
            _destinationDomain,
            _mintRecipient,
            _burnToken,
            _destinationCaller,
            _maxFee,
            _minFinalityThreshold
        );
        depositForBurnCalls.push(lastDepositForBurnCall);
        emit DepositForBurnCalled(
            _amount,
            _destinationDomain,
            _mintRecipient,
            _burnToken,
            _destinationCaller,
            _maxFee,
            _minFinalityThreshold
        );
    }

    /**
     * @notice Returns the fee recipient address - used by CircleCCTPAdapter to detect V2.
     * @dev Must return a non-zero address for V2 detection to work.
     */
    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    function localMinter() external view returns (ITokenMinter) {
        return minter;
    }

    /**
     * @notice Get a specific depositForBurn call by index.
     */
    function getDepositForBurnCall(
        uint256 index
    )
        external
        view
        returns (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold
        )
    {
        DepositForBurnV2Call memory call = depositForBurnCalls[index];
        return (
            call.amount,
            call.destinationDomain,
            call.mintRecipient,
            call.burnToken,
            call.destinationCaller,
            call.maxFee,
            call.minFinalityThreshold
        );
    }
}
