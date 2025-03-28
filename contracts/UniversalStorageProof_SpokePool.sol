// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { IHelios } from "./external/interfaces/IHelios.sol";
import "./libraries/CircleCCTPAdapter.sol";

import "./SpokePool.sol";

/**
 * @notice Spoke pool capable of receiving data stored in L1 state via storage proof + Helios light client.
 * @dev This contract has one onlyOwner function to be used as an emergency fallback to relay a message to
 * this SpokePool in the case where the light-client is not functioning correctly. The owner is designed to be set
 * to a multisig contract on this chain.
 */
contract UniversalStorageProof_SpokePool is OwnableUpgradeable, SpokePool, CircleCCTPAdapter {
    /// @notice The data store contract that only the HubPool can write to. This spoke pool can only act on
    /// data that has been written to this store.
    address public immutable hubPoolStore;

    /// @notice The address of the Helios L1 light client contract.
    address public immutable helios;

    /// @notice The owner of this contract must wait until this amount of seconds have passed since the latest
    /// helios light client update to admin execute a message.
    uint256 public immutable ADMIN_UPDATE_BUFFER;

    /// @notice Stores all proofs verified to prevent replay attacks.
    mapping(bytes32 => bool) public verifiedProofs;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private _adminCallValidated;

    event VerifiedProof(bytes32 indexed dataHash, address caller);

    error NotTarget();
    error AdminCallAlreadySet();
    error SlotValueMismatch();
    error AdminCallNotValidated();
    error DelegateCallFailed();
    error AlreadyReceived();
    error NotImplemented();
    error AdminUpdateTooCloseToLastHeliosUpdate();

    // All calls that have admin privileges must be fired from within the receiveL1State method that validates that
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
        ITokenMessenger _cctpTokenMessenger
    )
        SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer)
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
     * @dev Any slot key's value on the HubPoolStore can be treated as a message to be executed on this contract, but
     * there is no way to update the HubPoolStore's storage to be a valid message has outside of the
     * expected use case (i.e. calling HubPoolStore.storeRelayMessageCalldata()). If we wanted to prevent this, we
     * could hardcode the slot index of the HubPoolStore's relayMessageCallData mapping and make the user pass in
     * the nonce used to store the _value in the HubPoolStore. But this is an unneccessary friction for the caller
     * since we don't think there is a way to exploit this.
     * @param _slotKey Slot storage hash.
     * @param _value Slot storage value, unhashed. Compared against hashed value in light client for slot key and
     * block number.
     * @param _blockNumber Block number in light client we want to check slot value of slot key
     */
    function receiveL1State(
        bytes32 _slotKey,
        bytes calldata _value,
        uint256 _blockNumber
    ) external validateInternalCalls {
        bytes32 expectedSlotValueHash = keccak256(_value);

        // Verify Helios light client has expected slot value.
        bytes32 slotValueHash = IHelios(helios).getStorageSlot(_blockNumber, hubPoolStore, _slotKey);
        if (expectedSlotValueHash != slotValueHash) {
            revert SlotValueMismatch();
        }

        // Validate state is intended to be sent to this contract. The target could have been set to the zero address
        // which is used by the StorageProof_Adapter to denote messages that can be sent to any target.
        (address target, bytes memory message) = abi.decode(_value, (address, bytes));
        if (target != address(0) && target != address(this)) {
            revert NotTarget();
        }

        // Prevent replay attacks. The slot key should be a hash of the nonce associated with this calldata in the
        // HubPoolStore, which maps the nonce to the _value.
        if (verifiedProofs[_slotKey]) {
            revert AlreadyReceived();
        }
        verifiedProofs[_slotKey] = true;
        emit VerifiedProof(_slotKey, msg.sender);

        _executeCalldata(message);
    }

    /**
     * @notice This function is only callable by the owner and is used as an emergency fallback to execute
     * calldata to this SpokePool in the case where the light-client is not functioning correctly.
     * @dev This function will revert if the last Helios update was less than ADMIN_UPDATE_BUFFER seconds ago.
     * @param message The calldata to execute on this contract.
     */
    function adminRelayMessage(bytes memory message) external onlyOwner validateInternalCalls {
        uint256 heliosHeadTimestamp = IHelios(helios).headTimestamp();
        if (heliosHeadTimestamp > block.timestamp || block.timestamp - heliosHeadTimestamp < ADMIN_UPDATE_BUFFER) {
            revert AdminUpdateTooCloseToLastHeliosUpdate();
        }
        _executeCalldata(message);
    }

    function _executeCalldata(bytes memory _calldata) internal {
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_calldata);
        if (!success) {
            revert DelegateCallFailed();
        }
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(withdrawalRecipient, amountToReturn);
        } else {
            revert NotImplemented();
        }
    }

    // Check that the admin call is only triggered by a receiveL1State() call.
    function _requireAdminSender() internal view override {
        if (!_adminCallValidated) {
            revert AdminCallNotValidated();
        }
    }
}
