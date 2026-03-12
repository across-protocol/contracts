// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable-v4/access/OwnableUpgradeable.sol";

import { IHelios } from "../interfaces/IHelios.sol";
import "../libraries/CircleCCTPAdapter.sol";

import "./SpokePoolTron.sol";

/**
 * @title Universal_SpokePoolTron
 * @notice Tron-compatible fork of Universal_SpokePool. Inherits from SpokePoolTron instead of SpokePool
 * to resolve the `isContract` ambiguity for solc 0.8.25 compatibility.
 * @dev See Universal_SpokePool.sol for full documentation.
 * @custom:security-contact bugs@across.to
 */
contract Universal_SpokePoolTron is OwnableUpgradeable, SpokePoolTron, CircleCCTPAdapter {
    address public immutable hubPoolStore;
    uint256 public constant HUB_POOL_STORE_CALLDATA_MAPPING_SLOT_INDEX = 0;
    address public immutable helios;
    uint256 public immutable ADMIN_UPDATE_BUFFER;

    mapping(uint256 => bool) public executedMessages;

    bool private _adminCallValidated;

    event RelayedCallData(uint256 indexed nonce, address caller);

    error NotTarget();
    error AdminCallAlreadySet();
    error SlotValueMismatch();
    error AdminCallNotValidated();
    error DelegateCallFailed();
    error AlreadyExecuted();
    error NotImplemented();
    error AdminUpdateTooCloseToLastHeliosUpdate();

    modifier validateInternalCalls() {
        if (_adminCallValidated) {
            revert AdminCallAlreadySet();
        }
        _adminCallValidated = true;
        _;
        _adminCallValidated = false;
    }

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
        SpokePoolTron(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer, _oftDstEid, _oftFeeCap)
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum)
    {
        ADMIN_UPDATE_BUFFER = _adminUpdateBufferSeconds;
        helios = _helios;
        hubPoolStore = _hubPoolStore;
    }

    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __Ownable_init();
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
    }

    function executeMessage(
        uint256 _messageNonce,
        bytes calldata _message,
        uint256 _blockNumber
    ) external validateInternalCalls {
        bytes32 slotKey = getSlotKey(_messageNonce);
        bytes32 expectedSlotValue = keccak256(_message);

        bytes32 slotValue = IHelios(helios).getStorageSlot(_blockNumber, hubPoolStore, slotKey);
        if (expectedSlotValue != slotValue) {
            revert SlotValueMismatch();
        }

        (address target, bytes memory message) = abi.decode(_message, (address, bytes));
        if (target != address(0) && target != address(this)) {
            revert NotTarget();
        }

        if (executedMessages[_messageNonce]) {
            revert AlreadyExecuted();
        }
        executedMessages[_messageNonce] = true;
        emit RelayedCallData(_messageNonce, msg.sender);

        _executeCalldata(message);
    }

    function adminExecuteMessage(bytes memory _message) external onlyOwner validateInternalCalls {
        uint256 heliosHeadTimestamp = IHelios(helios).headTimestamp();
        if (heliosHeadTimestamp > block.timestamp || block.timestamp - heliosHeadTimestamp < ADMIN_UPDATE_BUFFER) {
            revert AdminUpdateTooCloseToLastHeliosUpdate();
        }
        _executeCalldata(_message);
    }

    function getSlotKey(uint256 _nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(_nonce, HUB_POOL_STORE_CALLDATA_MAPPING_SLOT_INDEX));
    }

    function _executeCalldata(bytes memory _calldata) internal {
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_calldata);
        if (!success) {
            revert DelegateCallFailed();
        }
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        address oftMessenger = _getOftMessenger(l2TokenAddress);

        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(withdrawalRecipient, amountToReturn);
        } else if (oftMessenger != address(0)) {
            _fundedTransferViaOft(IERC20(l2TokenAddress), IOFT(oftMessenger), withdrawalRecipient, amountToReturn);
        } else {
            revert NotImplemented();
        }
    }

    function _requireAdminSender() internal view override {
        if (!_adminCallValidated) {
            revert AdminCallNotValidated();
        }
    }
}
