// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";

interface IHelios {
    function executionStateRoots(uint256) external view returns (bytes32);
}

interface ISP1Verifier {
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata proofBytes
    ) external view;
}

/**
 * @notice SP1 Spoke pool capable of receiving data stored in L1 state via SP1 + Helios light clients.
 */
contract SP1_SpokePool is SpokePool {
    // The public values stored on L1 that can be relayed into this contract when accompanied with an SP1 proof.
    struct ContractPublicValues {
        bytes32 stateRoot;
        address contractAddress;
        bytes contractCalldata;
        bytes contractOutput;
    }
    /// @notice The address of the HubPool contract. Checked against public values to ensure only state
    /// stored by HubPool is relayed.
    address public immutable hubPool;

    /// @notice The address of the SP1 verifier contract.
    address public verifier;

    /// @notice The address of the Helios light client contract.
    address public helios;

    /// @notice The verification key for the acrossCall program.
    bytes32 public acrossCallProgramVKey;

    /// @notice Stores all proofs verified to prevent replay attacks.
    mapping(bytes32 => bytes) public proofs;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private _adminCallValidated;

    event VerifiedProof(bytes32 indexed proofHash, address caller);

    error NotHubPool();
    error NotTarget();
    error AdminCallAlreadySet();
    error StateRootMismatch();
    error AdminCallNotValidated();
    error DelegateCallFailed();

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
        address _verifier,
        address _helios,
        bytes32 _acrossCallProgramVKey,
        address _hubPool,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {
        verifier = _verifier;
        helios = _helios;
        acrossCallProgramVKey = _acrossCallProgramVKey;
        hubPool = _hubPool;
    }

    /**
     * @notice This can be called by an EOA to relay call data stored on the HubPool on L1 into this contract.
     * @dev Consider making this an onlyOwner function so that only a priveleged EOA can relay state. This EOA
     * wouldn't be able to tamper with the _publicValues.
     * @param _publicValues L1 contract state we want to relay into this contract. Contains a message that will
     * be treated as calldata for a delegatecall into this contract.
     * @param _proofBytes Proof bytes for the public values.
     * @param _head Head number related to _publicValues.
     */
    function receiveL1State(
        bytes calldata _publicValues,
        bytes calldata _proofBytes,
        uint256 _head
    ) external validateInternalCalls {
        // Verify proof and public values match:
        ISP1Verifier(verifier).verifyProof(acrossCallProgramVKey, _publicValues, _proofBytes);
        ContractPublicValues memory publicValues = abi.decode(_publicValues, (ContractPublicValues));

        // Verify Helios light client is aware of the state root containing the public values:
        bytes32 executionStateRoot = IHelios(helios).executionStateRoots(_head);
        if (executionStateRoot != publicValues.stateRoot) {
            revert StateRootMismatch();
        }

        // Validate state is intended to be sent to this contract:
        (address _hubPool, address _target, bytes memory _message) = abi.decode(
            publicValues.contractCalldata,
            (address, address, bytes)
        );
        if (_hubPool != hubPool) {
            revert NotHubPool();
        }
        if (_target != address(this)) {
            revert NotTarget();
        }

        // Store proof to prevent replay attacks:
        bytes32 proofHash = keccak256(_proofBytes);
        proofs[proofHash] = _proofBytes;
        emit VerifiedProof(proofHash, msg.sender);

        // Execute the calldata:
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_message);
        if (!success) {
            revert DelegateCallFailed();
        }
    }

    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
    }

    function _bridgeTokensToHubPool(uint256, address) internal override {
        // This method is a no-op. If the chain intends to include bridging functionality, this must be overriden.
        // If not, leaving this unimplemented means this method may be triggered, but the result will be that no
        // balance is transferred.
    }

    // Check that the admin call is only triggered by a receiveL1State() call.
    function _requireAdminSender() internal view override {
        if (!_adminCallValidated) {
            revert AdminCallNotValidated();
        }
    }
}
