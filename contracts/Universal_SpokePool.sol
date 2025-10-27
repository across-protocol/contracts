// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { IHelios } from "./external/interfaces/IHelios.sol";
import "./libraries/CircleCCTPAdapter.sol";

import "./SpokePool.sol";

/**
 * @notice Spoke pool capable of executing calldata stored in L1 state via storage proof + Helios light client.
 * @dev This contract has one onlyOwner function to be used as an emergency fallback to execute a message to
 * this SpokePool in the case where the light-client is not functioning correctly. The owner is designed to be set
 * to a multisig contract on this chain.
 * @custom:security-contact bugs@across.to
 */
contract Universal_SpokePool is OwnableUpgradeable, SpokePool, CircleCCTPAdapter {
    /// @notice The data store contract that only the HubPool can write to. This spoke pool can only act on
    /// data that has been written to this store.
    address public immutable hubPoolStore;

    /// @notice Slot index of the HubPoolStore's relayMessageCallData mapping.
    uint256 public constant HUB_POOL_STORE_CALLDATA_MAPPING_SLOT_INDEX = 0;

    /// @notice The address of the Helios L1 light client contract.
    address public immutable helios;

    /// @notice The owner of this contract must wait until this amount of seconds have passed since the latest
    /// helios light client update to emergency execute a message. This prevents the owner from executing a message
    /// in the happy case where the light client is being regularly updated. Therefore, this value should be
    /// set to a very high value, like 24 hours.
    uint256 public immutable ADMIN_UPDATE_BUFFER;

    /// @notice Stores nonces of calldata stored in HubPoolStore that gets executed via executeMessage()
    /// to prevent replay attacks.
    mapping(uint256 => bool) public executedMessages;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private _adminCallValidated;

    /// @notice Event emitted after off-chain agent sees HubPoolStore's emitted StoredCallData event and calls
    /// executeMessage() on this contract to relay the stored calldata.
    event RelayedCallData(uint256 indexed nonce, address caller);

    error NotTarget();
    error AdminCallAlreadySet();
    error SlotValueMismatch();
    error AdminCallNotValidated();
    error DelegateCallFailed();
    error AlreadyExecuted();
    error NotImplemented();
    error AdminUpdateTooCloseToLastHeliosUpdate();

    // All calls that have admin privileges must be fired from within the executeMessage method that validates that
    // the input data was published on L1 by the HubPool. This input data is then executed on this contract.
    // This modifier sets the adminCallValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
        // Make sure adminCallValidated is set to True only once at beginning of the function, which prevents
        // the function from being re-entered.
        if (_adminCallValidated) {
            revert AdminCallAlreadySet();
        }

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed.
        _adminCallValidated = true;

        _;

        // Reset adminCallValidated to false to disallow admin calls after this method exits.
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
        SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer, _oftDstEid, _oftFeeCap)
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

    /**
     * @notice Relays calldata stored by the HubPool on L1 into this contract.
     * @dev Replay attacks are possible with this _message if this contract has the same address on another chain.
     * @param _messageNonce Nonce of message stored in HubPoolStore.
     * @param _message Message stored in HubPoolStore's relayMessageCallData mapping. Compared against raw value
     * in Helios light client for slot key corresponding to _messageNonce at block number.
     * @param _blockNumber Block number in light client we use to check slot value of slot key
     */
    function executeMessage(
        uint256 _messageNonce,
        bytes calldata _message,
        uint256 _blockNumber
    ) external validateInternalCalls {
        bytes32 slotKey = getSlotKey(_messageNonce);
        // The expected slot value corresponds to the hash of the L2 calldata and its target,
        // as originally stored in the HubPoolStore's relayMessageCallData mapping.
        bytes32 expectedSlotValue = keccak256(_message);

        // Verify Helios light client has expected slot value.
        bytes32 slotValue = IHelios(helios).getStorageSlot(_blockNumber, hubPoolStore, slotKey);
        if (expectedSlotValue != slotValue) {
            revert SlotValueMismatch();
        }

        // Validate state is intended to be sent to this contract. The target could have been set to the zero address
        // which is used by the StorageProof_Adapter to denote messages that can be sent to any target.
        (address target, bytes memory message) = abi.decode(_message, (address, bytes));
        if (target != address(0) && target != address(this)) {
            revert NotTarget();
        }

        // Prevent replay attacks. The slot key should be a hash of the nonce associated with this calldata in the
        // HubPoolStore, which maps the nonce to the _value.
        if (executedMessages[_messageNonce]) {
            revert AlreadyExecuted();
        }
        executedMessages[_messageNonce] = true;
        emit RelayedCallData(_messageNonce, msg.sender);

        _executeCalldata(message);
    }

    /**
     * @notice This function is only callable by the owner and is used as an emergency fallback to execute
     * calldata to this SpokePool in the case where the light-client is not able to be updated.
     * @dev This function will revert if the last Helios update was less than ADMIN_UPDATE_BUFFER seconds ago.
     * @param _message The calldata to execute on this contract.
     */
    function adminExecuteMessage(bytes memory _message) external onlyOwner validateInternalCalls {
        uint256 heliosHeadTimestamp = IHelios(helios).headTimestamp();
        if (heliosHeadTimestamp > block.timestamp || block.timestamp - heliosHeadTimestamp < ADMIN_UPDATE_BUFFER) {
            revert AdminUpdateTooCloseToLastHeliosUpdate();
        }
        _executeCalldata(_message);
    }

    /**
     * @notice Computes the EVM storage slot key for a message nonce using the formula keccak256(key, slotIndex)
     * to find the storage slot for a value within a mapping(key=>value) at a slot index. We already know the
     * slot index of the relayMessageCallData mapping in the HubPoolStore.
     * @param _nonce The nonce associated with the message.
     * @return The computed storage slot key.
     */
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

    // Check that the admin call is only triggered by a executeMessage() call.
    function _requireAdminSender() internal view override {
        if (!_adminCallValidated) {
            revert AdminCallNotValidated();
        }
    }
}
