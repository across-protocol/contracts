// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./libraries/CircleCCTPAdapter.sol";

/// @dev This code is inspired by the R0 example here: https://github.com/risc0/risc0-ethereum/blob/main/examples/erc20-counter/contracts/src/Counter.sol.
///      One important difference is that the reference example shows how to verify a proof of state on the same chain
///      that the contract exists on. Steel does not currently have suport for verifying a proof of state
///      on a different chain, using a light client, so we verify te Steel Commitment against the SP1Helios light client
///      to ensure that the L1 state was included on L1 consensus.

interface IHeliosSteelValidator {
    struct Commitment {
        uint256 id;
        bytes32 digest;
        bytes32 configID;
    }

    function validateCommitment(Commitment calldata commitment) external view returns (bool);
}

/// @notice Verifier interface for RISC Zero receipts of execution.
interface IRiscZeroVerifier {
    /// @notice Verify that the given seal is a valid RISC Zero proof of execution with the
    ///     given image ID and journal digest. Reverts on failure.
    /// @dev This method additionally ensures that the input hash is all-zeros (i.e. no
    /// committed input), the exit code is (Halted, 0), and there are no assumptions (i.e. the
    /// receipt is unconditional).
    /// @param seal The encoded cryptographic proof (i.e. SNARK).
    /// @param imageId The identifier for the guest program.
    /// @param journalDigest The SHA-256 digest of the journal bytes.
    function verify(
        bytes calldata seal,
        bytes32 imageId,
        bytes32 journalDigest
    ) external view;
}

/**
 * @notice R0 Spoke pool capable of receiving data stored in L1 state via RiscZero Steel + Helios light client.
 * This contract uses RiscZero Steel to verify L1 event inclusion proofs in order to relay messages included
 * in L1 events to this contract.
 */
contract R0_SpokePool is SpokePool, CircleCCTPAdapter {
    /// @notice Journal that is committed to by the guest. Contains a unique identifier of a
    // UniversalAdapter event: "RelayedMessage(address,bytes)"
    struct Journal {
        IHeliosSteelValidator.Commitment commitment;
        bytes32 eventKey; // hash(eventSignature, eventParams, blockHash, txnHash, logIndex) ?
        address eventParams_target; // param0
        bytes eventParams_message; // param1
        address contractAddress; // address of emitting contract
    }

    /// @notice The address store that only the HubPool can write to. Checked against Journal to ensure only state
    /// stored by HubPool is relayed.
    address public immutable hubPoolStore;

    /// @notice The address of the R0 verifier contract.
    address public immutable verifier;

    /// @notice The address of the Helios-Steel validator contract.
    address public immutable steel;

    /// @notice The identifier for the guest program that generates event inclusion proofs.
    bytes32 public immutable imageId = bytes32("TODO");

    /// @notice Stores all proofs verified to prevent replay attacks.
    mapping(bytes32 => bool) public verifiedProofs;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private _adminCallValidated;

    event VerifiedProof(bytes32 indexed dataHash, address caller);

    error NotHubPoolStore();
    error NotTarget();
    error AdminCallAlreadySet();
    error AdminCallNotValidated();
    error DelegateCallFailed();
    error AlreadyReceived();
    error NotImplemented();
    error InvalidSteelCommitment();

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
        address _steel,
        address _verifier,
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
        verifier = _verifier;
        steel = _steel;
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
     * @notice This can be called by an EOA to relay events that the HubPool emits on L1.
     * @param journal The public data written by the guest program
     * @param seal The encoded cryptographic proof (i.e. SNARK).
     */
    function receiveL1State(Journal calldata journal, bytes calldata seal) external validateInternalCalls {
        if (journal.contractAddress != hubPoolStore) {
            revert NotHubPoolStore();
        }
        if (journal.eventParams_target != address(this)) {
            revert NotTarget();
        }
        if (IHeliosSteelValidator(steel).validateCommitment(journal.commitment)) {
            revert InvalidSteelCommitment();
        }

        // Verify the proof
        bytes32 journalHash = sha256(abi.encode(journal));
        IRiscZeroVerifier(verifier).verify(seal, imageId, journalHash);

        // Prevent replay attacks by using event key which includes block information from when the event was
        // emitted. The only way for someone to re-execute an identical message on this target spoke pool would
        // be to get the HubPool to re-publish the data. This lets the HubPool owner re-execute admin actions
        // that have the same calldata.
        bytes32 dataHash = bytes32(journal.eventKey);
        if (verifiedProofs[dataHash]) {
            revert AlreadyReceived();
        }
        verifiedProofs[dataHash] = true;
        emit VerifiedProof(dataHash, msg.sender);

        // Execute the calldata:
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(journal.eventParams_message);
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
