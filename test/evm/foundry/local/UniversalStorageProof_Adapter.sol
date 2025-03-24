// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { UniversalStorageProof_Adapter, HubPoolStore } from "../../../../contracts/chain-adapters/UniversalStorageProof_Adapter.sol";
import { MockHubPool } from "../../../../contracts/test/MockHubPool.sol";

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
        adapter = new UniversalStorageProof_Adapter(store, adapterStore, 10, 10, 1e18);
        hubPool.changeAdapter(address(adapter));
    }

    function testRelayMessage_relayRootBundle() public {
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        vm.expectCall(
            address(store),
            abi.encodeWithSignature(
                "storeDataForTargetWithNonce(address,bytes,uint256)",
                relayRootBundleTargetAddress,
                message,
                relayRootBundleNonce
            )
        );
        hubPool.arbitraryMessage(spokePoolTarget, message);
        bytes32 expectedDataHash = keccak256(abi.encode(relayRootBundleTargetAddress, message, relayRootBundleNonce));
        assertEq(store.storedData(expectedDataHash), abi.encode(relayRootBundleTargetAddress, message));
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
            abi.encodeWithSignature("storeDataForTarget(address,bytes)", spokePoolTarget, message)
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
        assertEq(store.storedData(expectedDataHash), abi.encode(spokePoolTarget, message));
    }
}
