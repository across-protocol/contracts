// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ISP1Verifier } from "@sp1-contracts/src/ISP1Verifier.sol";
import { AccessControlEnumerable } from "@sp1-contracts/lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

/// @title SP1HeliosTron
/// @notice Tron-compatible version of SP1Helios (uses if/revert instead of require with custom errors
/// for solc 0.8.25 compatibility).
/// @dev See SP1Helios.sol for full documentation.
/// @custom:security-contact bugs@across.to
contract SP1HeliosTron is AccessControlEnumerable {
    uint256 public immutable GENESIS_TIME;
    uint256 public immutable SECONDS_PER_SLOT;
    uint256 public immutable SLOTS_PER_PERIOD;
    uint256 public immutable SLOTS_PER_EPOCH;

    bytes32 public constant STATE_UPDATER_ROLE = keccak256("STATE_UPDATER_ROLE");
    bytes32 public constant VKEY_UPDATER_ROLE = keccak256("VKEY_UPDATER_ROLE");
    uint256 public constant MAX_SLOT_AGE = 1 weeks;

    uint256 public head;
    mapping(uint256 beaconSlot => bytes32 beaconHeaderRoot) public headers;
    mapping(uint256 beaconSlot => bytes32 executionStateRoot) public executionStateRoots;
    mapping(uint256 syncCommitteePeriod => bytes32 syncCommitteeHash) public syncCommittees;
    mapping(bytes32 computedStorageKey => bytes32 storageValue) public storageValues;

    bytes32 public heliosProgramVkey;
    address public immutable verifier;

    struct StorageSlot {
        bytes32 key;
        bytes32 value;
        address contractAddress;
    }

    struct ProofOutputs {
        bytes32 executionStateRoot;
        bytes32 newHeader;
        bytes32 nextSyncCommitteeHash;
        uint256 newHead;
        bytes32 prevHeader;
        uint256 prevHead;
        bytes32 syncCommitteeHash;
        bytes32 startSyncCommitteeHash;
        StorageSlot[] slots;
    }

    struct InitParams {
        bytes32 executionStateRoot;
        uint256 genesisTime;
        uint256 head;
        bytes32 header;
        bytes32 heliosProgramVkey;
        uint256 secondsPerSlot;
        uint256 slotsPerEpoch;
        uint256 slotsPerPeriod;
        bytes32 syncCommitteeHash;
        address verifier;
        address vkeyUpdater;
        address[] updaters;
    }

    event HeadUpdate(uint256 indexed slot, bytes32 indexed root);
    event SyncCommitteeUpdate(uint256 indexed period, bytes32 indexed root);
    event StorageSlotVerified(uint256 indexed head, bytes32 indexed key, bytes32 value, address contractAddress);
    event HeliosProgramVkeyUpdated(bytes32 indexed oldHeliosProgramVkey, bytes32 indexed newHeliosProgramVkey);

    error NonIncreasingHead(uint256 slot);
    error SyncCommitteeAlreadySet(uint256 period);
    error NewHeaderMismatch(uint256 slot);
    error ExecutionStateRootMismatch(uint256 slot);
    error SyncCommitteeStartMismatch(bytes32 given, bytes32 expected);
    error PreviousHeaderNotSet(uint256 slot);
    error PreviousHeaderMismatch(bytes32 given, bytes32 expected);
    error PreviousHeadTooOld(uint256 slot);
    error VkeyNotChanged(bytes32 vkey);

    constructor(InitParams memory params) {
        GENESIS_TIME = params.genesisTime;
        SECONDS_PER_SLOT = params.secondsPerSlot;
        SLOTS_PER_PERIOD = params.slotsPerPeriod;
        SLOTS_PER_EPOCH = params.slotsPerEpoch;
        syncCommittees[getSyncCommitteePeriod(params.head)] = params.syncCommitteeHash;
        heliosProgramVkey = params.heliosProgramVkey;
        headers[params.head] = params.header;
        executionStateRoots[params.head] = params.executionStateRoot;
        head = params.head;
        verifier = params.verifier;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        if (params.vkeyUpdater != address(0)) {
            _grantRole(VKEY_UPDATER_ROLE, params.vkeyUpdater);
        }

        for (uint256 i = 0; i < params.updaters.length; ++i) {
            address updater = params.updaters[i];
            if (updater != address(0)) {
                _grantRole(STATE_UPDATER_ROLE, updater);
            }
        }
    }

    function update(bytes calldata proof, bytes calldata publicValues) external onlyRole(STATE_UPDATER_ROLE) {
        ProofOutputs memory po = abi.decode(publicValues, (ProofOutputs));

        uint256 fromHead = po.prevHead;
        if (po.newHead <= fromHead) revert NonIncreasingHead(po.newHead);

        bytes32 storedPrevHeader = headers[fromHead];
        if (storedPrevHeader == bytes32(0)) revert PreviousHeaderNotSet(fromHead);
        if (storedPrevHeader != po.prevHeader) revert PreviousHeaderMismatch(po.prevHeader, storedPrevHeader);

        if (block.timestamp - slotTimestamp(fromHead) > MAX_SLOT_AGE) revert PreviousHeadTooOld(fromHead);

        uint256 currentPeriod = getSyncCommitteePeriod(fromHead);

        bytes32 currentSyncCommitteeHash = syncCommittees[currentPeriod];
        if (currentSyncCommitteeHash != po.startSyncCommitteeHash) {
            revert SyncCommitteeStartMismatch(po.startSyncCommitteeHash, currentSyncCommitteeHash);
        }

        ISP1Verifier(verifier).verifyProof(heliosProgramVkey, publicValues, proof);

        bytes32 storedNewHeader = headers[po.newHead];
        if (storedNewHeader == bytes32(0)) {
            headers[po.newHead] = po.newHeader;
        } else if (storedNewHeader != po.newHeader) {
            revert NewHeaderMismatch(po.newHead);
        }

        if (head < po.newHead) {
            head = po.newHead;
            emit HeadUpdate(po.newHead, po.newHeader);
        }

        bytes32 storedExecutionRoot = executionStateRoots[po.newHead];
        if (storedExecutionRoot == bytes32(0)) {
            executionStateRoots[po.newHead] = po.executionStateRoot;
        } else if (storedExecutionRoot != po.executionStateRoot) {
            revert ExecutionStateRootMismatch(po.newHead);
        }

        for (uint256 i = 0; i < po.slots.length; ++i) {
            StorageSlot memory slot = po.slots[i];
            bytes32 storageKey = computeStorageKey(po.newHead, slot.contractAddress, slot.key);
            storageValues[storageKey] = slot.value;
            emit StorageSlotVerified(po.newHead, slot.key, slot.value, slot.contractAddress);
        }

        uint256 newPeriod = getSyncCommitteePeriod(po.newHead);

        if (syncCommittees[newPeriod] == bytes32(0)) {
            syncCommittees[newPeriod] = po.syncCommitteeHash;
            emit SyncCommitteeUpdate(newPeriod, po.syncCommitteeHash);
        }
        if (po.nextSyncCommitteeHash != bytes32(0)) {
            uint256 nextPeriod = newPeriod + 1;

            if (syncCommittees[nextPeriod] != po.nextSyncCommitteeHash) {
                if (syncCommittees[nextPeriod] != bytes32(0)) revert SyncCommitteeAlreadySet(nextPeriod);

                syncCommittees[nextPeriod] = po.nextSyncCommitteeHash;
                emit SyncCommitteeUpdate(nextPeriod, po.nextSyncCommitteeHash);
            }
        }
    }

    function updateHeliosProgramVkey(bytes32 newHeliosProgramVkey) external onlyRole(VKEY_UPDATER_ROLE) {
        bytes32 oldHeliosProgramVkey = heliosProgramVkey;
        heliosProgramVkey = newHeliosProgramVkey;

        if (oldHeliosProgramVkey == newHeliosProgramVkey) revert VkeyNotChanged(newHeliosProgramVkey);

        emit HeliosProgramVkeyUpdated(oldHeliosProgramVkey, newHeliosProgramVkey);
    }

    function getSyncCommitteePeriod(uint256 slot) public view returns (uint256) {
        return slot / SLOTS_PER_PERIOD;
    }

    function getCurrentEpoch() external view returns (uint256) {
        return head / SLOTS_PER_EPOCH;
    }

    function slotTimestamp(uint256 slot) public view returns (uint256) {
        return GENESIS_TIME + slot * SECONDS_PER_SLOT;
    }

    function headTimestamp() external view returns (uint256) {
        return slotTimestamp(head);
    }

    function computeStorageKey(
        uint256 beaconSlot,
        address contractAddress,
        bytes32 storageSlot
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(beaconSlot, contractAddress, storageSlot));
    }

    function getStorageSlot(
        uint256 beaconSlot,
        address contractAddress,
        bytes32 storageSlot
    ) external view returns (bytes32) {
        return storageValues[computeStorageKey(beaconSlot, contractAddress, storageSlot)];
    }
}
