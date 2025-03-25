// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { UniversalStorageProof_Adapter, HubPoolStore } from "../../../../contracts/chain-adapters/UniversalStorageProof_Adapter.sol";
import { MockHubPool } from "../../../../contracts/test/MockHubPool.sol";
import "../../../../contracts/libraries/CircleCCTPAdapter.sol";

contract UniversalStorageProofAdapterTest is Test {
    UniversalStorageProof_Adapter adapter;
    HubPoolStore store;
    MockHubPool hubPool;
    address spokePoolTarget;

    uint256 relayRootBundleNonce = 0;
    address relayRootBundleTargetAddress = address(0);
    address adapterStore = address(0);

    function setUp() public {
        spokePoolTarget = vm.addr(1);
        hubPool = new MockHubPool(address(0));
        store = new HubPoolStore(address(hubPool));
        adapter = new UniversalStorageProof_Adapter(store, IERC20(address(0)), ITokenMessenger(address(0)), 0);
        hubPool.changeAdapter(address(adapter));
    }

    function testRelayMessage_relayRootBundle() public {
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.expectCall(address(store), abi.encodeWithSignature("storeRelayRootsCalldata(bytes)", message));
        hubPool.arbitraryMessage(spokePoolTarget, message);
        uint256 challengePeriodTimestamp = hubPool.rootBundleProposal().challengePeriodEndTimestamp;
        bytes32 expectedDataHash = keccak256(abi.encode(address(0), message, challengePeriodTimestamp));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(address(0), message));
    }

    function testRelayMessage_relayRootBundle_duplicate() public {
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.recordLogs();
        hubPool.arbitraryMessage(spokePoolTarget, message);
        hubPool.arbitraryMessage(spokePoolTarget, message);
        uint256 challengePeriodTimestamp = hubPool.rootBundleProposal().challengePeriodEndTimestamp;
        bytes32 expectedDataHash = keccak256(abi.encode(address(0), message, challengePeriodTimestamp));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(address(0), message));
        // Each arbitraryMessage call should emit one MessageRelayed event, but only
        // the first one should emit a `StoredRootBundleData` event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], keccak256("StoredAdminFunctionData(bytes32,address,bytes,uint256,bytes)"));
        assertEq(logs[1].topics[0], keccak256("MessageRelayed(address,bytes)"));
        assertEq(logs[2].topics[0], keccak256("MessageRelayed(address,bytes)"));
    }

    function testRelayMessage_relayRootBundle_differentNonce() public {
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.recordLogs();
        hubPool.arbitraryMessage(spokePoolTarget, message);
        hubPool.arbitraryMessage(spokePoolTarget, message);
        uint256 challengePeriodTimestamp = hubPool.rootBundleProposal().challengePeriodEndTimestamp;
        bytes32 expectedDataHash = keccak256(abi.encode(address(0), message, challengePeriodTimestamp));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(address(0), message));

        // Change the challenge period timestamp.
        uint32 newChallengePeriodTimestamp = 123;
        hubPool.setChallengePeriodTimestamp(newChallengePeriodTimestamp);
        hubPool.arbitraryMessage(spokePoolTarget, message);
        bytes32 expectedDataHash_2 = keccak256(abi.encode(address(0), message, newChallengePeriodTimestamp));
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash_2), abi.encode(address(0), message));

        // Old data hash is unaffected.
        assertEq(store.relayAdminFunctionCalldata(expectedDataHash), abi.encode(address(0), message));
        assertNotEq(expectedDataHash, expectedDataHash_2);
    }

    function testRelayMessage() public {
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

    function testRelayIncrementsNonce() public {
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
}
