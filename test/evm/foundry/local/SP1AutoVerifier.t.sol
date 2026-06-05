// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { SP1Helios } from "../../../../contracts/sp1-helios/SP1Helios.sol";
import { SP1AutoVerifier } from "../../../../contracts/sp1-helios/SP1AutoVerifier.sol";

contract SP1AutoVerifierTest is Test {
    SP1AutoVerifier autoVerifier;
    SP1Helios helios;
    address updater = address(0x2);

    uint256 constant GENESIS_TIME = 1606824023;
    uint256 constant SECONDS_PER_SLOT = 12;
    uint256 constant SLOTS_PER_EPOCH = 32;
    uint256 constant SLOTS_PER_PERIOD = 8192;
    bytes32 constant INITIAL_HEADER = bytes32(uint256(2));
    bytes32 constant INITIAL_EXECUTION_STATE_ROOT = bytes32(uint256(3));
    bytes32 constant INITIAL_SYNC_COMMITTEE_HASH = bytes32(uint256(4));
    bytes32 constant HELIOS_PROGRAM_VKEY = bytes32(uint256(5));
    uint256 constant INITIAL_HEAD = 100;

    function setUp() public {
        autoVerifier = new SP1AutoVerifier();

        address[] memory updaters = new address[](1);
        updaters[0] = updater;

        helios = new SP1Helios(
            SP1Helios.InitParams({
                executionStateRoot: INITIAL_EXECUTION_STATE_ROOT,
                genesisTime: GENESIS_TIME,
                head: INITIAL_HEAD,
                header: INITIAL_HEADER,
                heliosProgramVkey: HELIOS_PROGRAM_VKEY,
                secondsPerSlot: SECONDS_PER_SLOT,
                slotsPerEpoch: SLOTS_PER_EPOCH,
                slotsPerPeriod: SLOTS_PER_PERIOD,
                syncCommitteeHash: INITIAL_SYNC_COMMITTEE_HASH,
                verifier: address(autoVerifier),
                vkeyUpdater: address(0),
                updaters: updaters
            })
        );
    }

    function testVerifyProofNeverReverts() public view {
        autoVerifier.verifyProof(bytes32(0), "", "");
        autoVerifier.verifyProof(bytes32(uint256(1)), "abc", "def");
        autoVerifier.verifyProof(HELIOS_PROGRAM_VKEY, abi.encode(uint256(42)), hex"deadbeef");
    }

    function testHeliosUpdateWithNonEmptyProof() public {
        SP1Helios.StorageSlot[] memory slots = new SP1Helios.StorageSlot[](0);
        SP1Helios.ProofOutputs memory po = SP1Helios.ProofOutputs({
            executionStateRoot: bytes32(uint256(11)),
            newHeader: bytes32(uint256(10)),
            nextSyncCommitteeHash: bytes32(0),
            newHead: INITIAL_HEAD + 1,
            prevHeader: INITIAL_HEADER,
            prevHead: INITIAL_HEAD,
            syncCommitteeHash: INITIAL_SYNC_COMMITTEE_HASH,
            startSyncCommitteeHash: INITIAL_SYNC_COMMITTEE_HASH,
            slots: slots
        });

        vm.warp(helios.slotTimestamp(INITIAL_HEAD) + 1 hours);
        vm.prank(updater);
        // Unlike SP1MockVerifier, non-empty proof bytes are accepted.
        // Note: the ProofVerified event is NOT emitted here because SP1Helios calls verifyProof
        // via staticcall (ISP1Verifier is view), which prevents state changes including events.
        helios.update(hex"deadbeef", abi.encode(po));

        assertEq(helios.head(), INITIAL_HEAD + 1);
    }
}
