// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { UniversalStorageProof_Adapter, HubPoolStore } from "../../../../contracts/chain-adapters/UniversalStorageProof_Adapter.sol";
import { MockHubPool } from "../../../../contracts/test/MockHubPool.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import "../../../../contracts/libraries/CircleCCTPAdapter.sol";

contract UniversalStorageProofAdapterTest is Test {
    UniversalStorageProof_Adapter adapter;
    HubPoolStore store;
    MockHubPool hubPool;
    address spokePoolTarget;

    uint256 relayRootBundleNonce = 0;
    address relayRootBundleTargetAddress = address(0);
    address adapterStore = address(0);
    // Set challengePeriodEndTimestamp to current time to simulate when a root bundle is executed.
    HubPoolInterface.RootBundle pendingRootBundle =
        HubPoolInterface.RootBundle({
            challengePeriodEndTimestamp: uint32(block.timestamp),
            poolRebalanceRoot: bytes32("poolRoot"),
            relayerRefundRoot: bytes32("refundRoot"),
            slowRelayRoot: bytes32("slowRoot"),
            claimedBitMap: 0,
            proposer: address(0),
            unclaimedPoolRebalanceLeafCount: 0
        });
    uint32 challengePeriodTimestamp = pendingRootBundle.challengePeriodEndTimestamp;

    function setUp() public {
        spokePoolTarget = vm.addr(1);
        hubPool = new MockHubPool(address(0));
        store = new HubPoolStore(address(hubPool));
        adapter = new UniversalStorageProof_Adapter(store, IERC20(address(0)), ITokenMessenger(address(0)), 0);
        hubPool.changeAdapter(address(adapter));
        hubPool.setPendingRootBundle(pendingRootBundle);
    }

    function testRelayMessage_relayRootBundle() public {
        bytes32 refundRoot = pendingRootBundle.relayerRefundRoot;
        bytes32 slowRelayRoot = pendingRootBundle.slowRelayRoot;
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.expectCall(
            address(store),
            abi.encodeWithSignature("storeRelayRootsCalldata(address,bytes)", spokePoolTarget, message)
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);

        // Target gets overwritten to 0x in the data hash.
        bytes32 expectedDataHash = keccak256(
            abi.encode(relayRootBundleTargetAddress, message, challengePeriodTimestamp)
        );
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(relayRootBundleTargetAddress, message));
    }

    function testRelayMessage_relayRootBundle_duplicate() public {
        bytes32 refundRoot = pendingRootBundle.relayerRefundRoot;
        bytes32 slowRelayRoot = pendingRootBundle.slowRelayRoot;
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.recordLogs();
        hubPool.arbitraryMessage(spokePoolTarget, message);
        hubPool.arbitraryMessage(spokePoolTarget, message);
        bytes32 expectedDataHash = keccak256(
            abi.encode(relayRootBundleTargetAddress, message, challengePeriodTimestamp)
        );
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(relayRootBundleTargetAddress, message));
        // Each arbitraryMessage call should emit one MessageRelayed event, but only
        // the first one should emit a `StoredRootBundleData` event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], keccak256("StoredAdminFunctionData(bytes32,address,bytes,uint256,bytes)"));
        assertEq(logs[1].topics[0], keccak256("MessageRelayed(address,bytes)"));
        assertEq(logs[2].topics[0], keccak256("MessageRelayed(address,bytes)"));
    }

    function testRelayMessage_relayRootBundle_differentNonce() public {
        bytes32 refundRoot = pendingRootBundle.relayerRefundRoot;
        bytes32 slowRelayRoot = pendingRootBundle.slowRelayRoot;
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.recordLogs();
        hubPool.arbitraryMessage(spokePoolTarget, message);
        hubPool.arbitraryMessage(spokePoolTarget, message);
        bytes32 expectedDataHash = keccak256(
            abi.encode(relayRootBundleTargetAddress, message, challengePeriodTimestamp)
        );
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(relayRootBundleTargetAddress, message));

        // Change the challenge period timestamp. Remember to warp block.time >= challengePeriodTimestamp to make
        // HubPoolStore treat this call as a normal relayRootBundle call.
        // We need block.timestamp >= challengePeriodTimestamp.
        uint32 newChallengePeriodTimestamp = challengePeriodTimestamp + 1;
        vm.warp(newChallengePeriodTimestamp);
        pendingRootBundle.challengePeriodEndTimestamp = newChallengePeriodTimestamp;
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: newChallengePeriodTimestamp,
                poolRebalanceRoot: pendingRootBundle.poolRebalanceRoot,
                relayerRefundRoot: pendingRootBundle.relayerRefundRoot,
                slowRelayRoot: pendingRootBundle.slowRelayRoot,
                claimedBitMap: pendingRootBundle.claimedBitMap,
                proposer: pendingRootBundle.proposer,
                unclaimedPoolRebalanceLeafCount: pendingRootBundle.unclaimedPoolRebalanceLeafCount
            })
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
        bytes32 expectedDataHash_2 = keccak256(
            abi.encode(relayRootBundleTargetAddress, message, newChallengePeriodTimestamp)
        );
        assertEq(
            store.relayAdminFunctionCalldata(expectedDataHash_2),
            abi.encode(relayRootBundleTargetAddress, message)
        );

        // Old data hash is unaffected.
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(relayRootBundleTargetAddress, message));
        assertNotEq(expectedDataHash, expectedDataHash_2);
    }

    function testRelayMessage_relayAdminFunction() public {
        address originToken = makeAddr("origin");
        uint256 destinationChainId = 111;
        bytes memory message = abi.encodeWithSignature(
            "setEnableRoute(address,uint256,bool)",
            originToken,
            destinationChainId,
            true
        );
        vm.expectCall(
            address(store),
            abi.encodeWithSignature("storeRelayAdminFunctionCalldata(address,bytes)", spokePoolTarget, message)
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
    }

    function testRelayMessage_relayAdminFunction_incrementsNonce() public {
        address originToken = makeAddr("origin");
        uint256 destinationChainId = 111;
        bytes memory message = abi.encodeWithSignature(
            "setEnableRoute(address,uint256,bool)",
            originToken,
            destinationChainId,
            true
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
        hubPool.arbitraryMessage(spokePoolTarget, message);

        // Test that second call increments nonce of data.
        uint256 expectedNonce = 1;
        bytes32 expectedDataHash = keccak256(abi.encode(spokePoolTarget, message, expectedNonce));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(spokePoolTarget, message));
    }

    function testRelayMessage_relayAdminFunction_relayAdminBundle() public {
        // Set challenge period timestamp to 0 to simulate relaying an admin bundle in between bundles. The global
        // nonce should be used.
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: 0,
                poolRebalanceRoot: pendingRootBundle.poolRebalanceRoot,
                relayerRefundRoot: pendingRootBundle.relayerRefundRoot,
                slowRelayRoot: pendingRootBundle.slowRelayRoot,
                claimedBitMap: pendingRootBundle.claimedBitMap,
                proposer: pendingRootBundle.proposer,
                unclaimedPoolRebalanceLeafCount: pendingRootBundle.unclaimedPoolRebalanceLeafCount
            })
        );

        bytes32 refundRoot = pendingRootBundle.relayerRefundRoot;
        bytes32 slowRelayRoot = pendingRootBundle.slowRelayRoot;
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        hubPool.arbitraryMessage(spokePoolTarget, message);
        uint256 expectedNonce = 0;

        // Relaying an admin root bundle uses the actual target in the data hash.
        bytes32 expectedDataHash = keccak256(abi.encode(spokePoolTarget, message, expectedNonce));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(spokePoolTarget, message));

        // Now try to relay an admin bundle when the challenge period timestamp is > block.timestamp
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: uint32(block.timestamp + 100),
                poolRebalanceRoot: pendingRootBundle.poolRebalanceRoot,
                relayerRefundRoot: pendingRootBundle.relayerRefundRoot,
                slowRelayRoot: pendingRootBundle.slowRelayRoot,
                claimedBitMap: pendingRootBundle.claimedBitMap,
                proposer: pendingRootBundle.proposer,
                unclaimedPoolRebalanceLeafCount: pendingRootBundle.unclaimedPoolRebalanceLeafCount
            })
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
        // Relaying an admin root bundle uses the global nonce, which will increment now:
        expectedNonce++;
        expectedDataHash = keccak256(abi.encode(spokePoolTarget, message, expectedNonce));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(spokePoolTarget, message));

        // Last way to send an admin root bundle is when the challenge period timestamp is <= block.timestamp and the
        // root bundle data is different from the pending root bundle data.
        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: uint32(block.timestamp),
                poolRebalanceRoot: pendingRootBundle.poolRebalanceRoot,
                relayerRefundRoot: pendingRootBundle.relayerRefundRoot,
                slowRelayRoot: bytes32("differentSlowRelayRoot"),
                claimedBitMap: pendingRootBundle.claimedBitMap,
                proposer: pendingRootBundle.proposer,
                unclaimedPoolRebalanceLeafCount: pendingRootBundle.unclaimedPoolRebalanceLeafCount
            })
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
        expectedNonce++;
        expectedDataHash = keccak256(abi.encode(spokePoolTarget, message, expectedNonce));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(spokePoolTarget, message));

        hubPool.setPendingRootBundle(
            HubPoolInterface.RootBundle({
                challengePeriodEndTimestamp: uint32(block.timestamp),
                poolRebalanceRoot: pendingRootBundle.poolRebalanceRoot,
                relayerRefundRoot: bytes32("differentRefundRoot"),
                slowRelayRoot: pendingRootBundle.slowRelayRoot,
                claimedBitMap: pendingRootBundle.claimedBitMap,
                proposer: pendingRootBundle.proposer,
                unclaimedPoolRebalanceLeafCount: pendingRootBundle.unclaimedPoolRebalanceLeafCount
            })
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
        expectedNonce++;
        expectedDataHash = keccak256(abi.encode(spokePoolTarget, message, expectedNonce));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(spokePoolTarget, message));
    }

    function testRelayTokens_cctp() public {
        // Uses CCTP to send USDC
    }

    function testRelayTokens_default() public {
        // Reverts
    }
}
