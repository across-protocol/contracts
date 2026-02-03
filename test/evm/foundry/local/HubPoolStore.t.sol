// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { HubPoolStore } from "../../../../contracts/chain-adapters/Universal_Adapter.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

/// @dev Simple mock that implements only what HubPoolStore needs from HubPool
contract MockHubPoolForStore {
    HubPoolInterface.RootBundle public rootBundleProposal;

    function setPendingRootBundle(HubPoolInterface.RootBundle memory _rootBundle) external {
        rootBundleProposal = _rootBundle;
    }
}

contract HubPoolStoreTest is Test {
    HubPoolStore store;
    MockHubPoolForStore hubPool;

    bytes message = abi.encode("message");
    address target = makeAddr("target");

    event StoredCallData(address indexed target, bytes data, uint256 indexed nonce);

    function setUp() public {
        hubPool = new MockHubPoolForStore();
        store = new HubPoolStore(address(hubPool));
    }

    // ============ Constructor Tests ============

    function testConstructor() public view {
        assertEq(store.hubPool(), address(hubPool));
    }

    // ============ Access Control Tests ============

    function testOnlyHubPoolCanStore() public {
        vm.expectRevert(HubPoolStore.NotHubPool.selector);
        store.storeRelayMessageCalldata(target, message, true);
    }

    function testOnlyHubPoolCanStore_arbitraryAddress() public {
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(HubPoolStore.NotHubPool.selector);
        store.storeRelayMessageCalldata(target, message, true);
    }

    // ============ Admin Message Tests (isAdminSender = true) ============

    function testStoreAdminMessage() public {
        vm.prank(address(hubPool));
        store.storeRelayMessageCalldata(target, message, true);

        // First admin message should use nonce 0
        assertEq(store.relayMessageCallData(0), keccak256(abi.encode(target, message)));
    }

    function testStoreAdminMessage_emitsEvent() public {
        vm.prank(address(hubPool));
        vm.expectEmit(true, true, true, true);
        emit StoredCallData(target, message, 0);
        store.storeRelayMessageCalldata(target, message, true);
    }

    function testStoreAdminMessage_incrementsNonce() public {
        vm.startPrank(address(hubPool));

        // First call uses nonce 0
        store.storeRelayMessageCalldata(target, message, true);
        assertEq(store.relayMessageCallData(0), keccak256(abi.encode(target, message)));

        // Second call uses nonce 1
        bytes memory message2 = abi.encode("message2");
        store.storeRelayMessageCalldata(target, message2, true);
        assertEq(store.relayMessageCallData(1), keccak256(abi.encode(target, message2)));

        // Third call uses nonce 2
        address target2 = makeAddr("target2");
        store.storeRelayMessageCalldata(target2, message, true);
        assertEq(store.relayMessageCallData(2), keccak256(abi.encode(target2, message)));

        vm.stopPrank();
    }

    function testStoreAdminMessage_includesTargetInHash() public {
        vm.startPrank(address(hubPool));

        // Same message but different targets should produce different hashes
        address target1 = makeAddr("target1");
        address target2 = makeAddr("target2");

        store.storeRelayMessageCalldata(target1, message, true);
        store.storeRelayMessageCalldata(target2, message, true);

        bytes32 hash1 = store.relayMessageCallData(0);
        bytes32 hash2 = store.relayMessageCallData(1);

        // Verify the hashes are different
        assertTrue(hash1 != hash2);

        // Verify each hash matches expected
        assertEq(hash1, keccak256(abi.encode(target1, message)));
        assertEq(hash2, keccak256(abi.encode(target2, message)));

        vm.stopPrank();
    }

    // ============ Non-Admin Message Tests (isAdminSender = false) ============

    function testStoreNonAdminMessage() public {
        uint32 challengePeriodTimestamp = uint32(block.timestamp);
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: challengePeriodTimestamp,
                poolRebalanceRoot: bytes32("poolRoot"),
                relayerRefundRoot: bytes32("refundRoot"),
                slowRelayRoot: bytes32("slowRoot"),
                claimedBitMap: 0,
                proposer: address(0),
                unclaimedPoolRebalanceLeafCount: 0
            })
        );

        vm.prank(address(hubPool));
        store.storeRelayMessageCalldata(target, message, false);

        // Non-admin message uses challengePeriodEndTimestamp as nonce
        // Target is overwritten to address(0) in the hash
        assertEq(store.relayMessageCallData(challengePeriodTimestamp), keccak256(abi.encode(address(0), message)));
    }

    function testStoreNonAdminMessage_emitsEvent() public {
        uint32 challengePeriodTimestamp = uint32(block.timestamp);
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: challengePeriodTimestamp,
                poolRebalanceRoot: bytes32(0),
                relayerRefundRoot: bytes32(0),
                slowRelayRoot: bytes32(0),
                claimedBitMap: 0,
                proposer: address(0),
                unclaimedPoolRebalanceLeafCount: 0
            })
        );

        vm.prank(address(hubPool));
        // Event should have address(0) as target for non-admin messages
        vm.expectEmit(true, true, true, true);
        emit StoredCallData(address(0), message, challengePeriodTimestamp);
        store.storeRelayMessageCalldata(target, message, false);
    }

    function testStoreNonAdminMessage_duplicateDoesNotOverwrite() public {
        uint32 challengePeriodTimestamp = uint32(block.timestamp);
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: challengePeriodTimestamp,
                poolRebalanceRoot: bytes32(0),
                relayerRefundRoot: bytes32(0),
                slowRelayRoot: bytes32(0),
                claimedBitMap: 0,
                proposer: address(0),
                unclaimedPoolRebalanceLeafCount: 0
            })
        );

        vm.startPrank(address(hubPool));

        // First call stores data
        vm.recordLogs();
        store.storeRelayMessageCalldata(target, message, false);

        // Second call with same challengePeriodTimestamp should NOT emit event
        // because data is already stored
        store.storeRelayMessageCalldata(target, message, false);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Only one StoredCallData event should be emitted
        uint256 storedCallDataCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("StoredCallData(address,bytes,uint256)")) {
                storedCallDataCount++;
            }
        }
        assertEq(storedCallDataCount, 1);

        // Data should still be the original
        assertEq(store.relayMessageCallData(challengePeriodTimestamp), keccak256(abi.encode(address(0), message)));

        vm.stopPrank();
    }

    function testStoreNonAdminMessage_differentTimestampCreatesNewEntry() public {
        uint32 timestamp1 = uint32(block.timestamp);
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: timestamp1,
                poolRebalanceRoot: bytes32(0),
                relayerRefundRoot: bytes32(0),
                slowRelayRoot: bytes32(0),
                claimedBitMap: 0,
                proposer: address(0),
                unclaimedPoolRebalanceLeafCount: 0
            })
        );

        vm.startPrank(address(hubPool));

        // Store first message
        store.storeRelayMessageCalldata(target, message, false);
        assertEq(store.relayMessageCallData(timestamp1), keccak256(abi.encode(address(0), message)));

        // Update to new timestamp
        uint32 timestamp2 = timestamp1 + 1;
        vm.warp(timestamp2);
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: timestamp2,
                poolRebalanceRoot: bytes32(0),
                relayerRefundRoot: bytes32(0),
                slowRelayRoot: bytes32(0),
                claimedBitMap: 0,
                proposer: address(0),
                unclaimedPoolRebalanceLeafCount: 0
            })
        );

        // Store second message with different data
        bytes memory message2 = abi.encode("different message");
        store.storeRelayMessageCalldata(target, message2, false);

        // Both entries should exist
        assertEq(store.relayMessageCallData(timestamp1), keccak256(abi.encode(address(0), message)));
        assertEq(store.relayMessageCallData(timestamp2), keccak256(abi.encode(address(0), message2)));

        vm.stopPrank();
    }

    function testStoreNonAdminMessage_targetIgnoredInHash() public {
        uint32 challengePeriodTimestamp = uint32(block.timestamp);
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: challengePeriodTimestamp,
                poolRebalanceRoot: bytes32(0),
                relayerRefundRoot: bytes32(0),
                slowRelayRoot: bytes32(0),
                claimedBitMap: 0,
                proposer: address(0),
                unclaimedPoolRebalanceLeafCount: 0
            })
        );

        vm.prank(address(hubPool));
        // Even though we pass a target, it should be replaced with address(0)
        store.storeRelayMessageCalldata(makeAddr("someTarget"), message, false);

        // Verify the hash uses address(0) not the passed target
        assertEq(store.relayMessageCallData(challengePeriodTimestamp), keccak256(abi.encode(address(0), message)));
    }
}
