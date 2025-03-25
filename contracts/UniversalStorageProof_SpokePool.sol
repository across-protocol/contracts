// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IHelios } from "./external/interfaces/IHelios.sol";
import "./libraries/CircleCCTPAdapter.sol";

import "./SpokePool.sol";

/**
 * @notice Spoke pool capable of receiving data stored in L1 state via storage proof + Helios light client.
 */
contract UniversalStorageProof_SpokePool is SpokePool, CircleCCTPAdapter {
    /// @notice The address store that only the HubPool can write to. Checked against public values to ensure only state
    /// stored by HubPool is relayed.
    address public immutable hubPoolStore;

    /// @notice The address of the Helios light client contract.
    address public immutable helios;

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
        helios = _helios;
        hubPoolStore = _hubPoolStore;
    }

    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
    }

    /**
     * @notice This can be called by an EOA to relay call data stored on the HubPool on L1 into this contract.
     * @dev Consider making this an onlyOwner function so that only a privileged EOA can relay state. This EOA
     * wouldn't be able to tamper with the _publicValues but we can reduce the chance of replay-attacks this way if
     * we set the EOA to a trusted actor. Replay attacks are possible if this contract has the same address
     * on multiple chains.
     * @param _slotKey Slot storage hash
     * @param _value Slot storage value
     * @param _blockNumber Block number in light client we want to check slot value of slot key
     */
    function receiveL1State(
        bytes32 _slotKey,
        bytes calldata _value,
        uint256 _blockNumber
    ) external validateInternalCalls {
        bytes32 expectedSlotValueHash = keccak256(_value);

        // Verify Helios light client is aware of the storage slot:
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

        // Prevent replay attacks.
        bytes32 dataHash = keccak256(abi.encode(_slotKey));
        if (verifiedProofs[dataHash]) {
            revert AlreadyReceived();
        }
        verifiedProofs[dataHash] = true;
        emit VerifiedProof(dataHash, msg.sender);

        // Execute the calldata:
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(message);
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
