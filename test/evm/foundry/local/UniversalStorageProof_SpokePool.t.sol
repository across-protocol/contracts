// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { UniversalStorageProof_SpokePool, IHelios } from "../../../../contracts/UniversalStorageProof_SpokePool.sol";
import "../../../../contracts/libraries/CircleCCTPAdapter.sol";

contract MockHelios is IHelios {
    mapping(bytes32 => bytes32) public storageSlots;

    function updateStorageSlot(bytes32 key, bytes32 valueHash) external {
        storageSlots[key] = valueHash;
    }

    function getStorageSlot(
        uint256,
        address,
        bytes32 _key
    ) external view returns (bytes32) {
        return storageSlots[_key];
    }
}

contract UniversalStorageProofSpokePoolTest is Test {
    UniversalStorageProof_SpokePool spokePool;
    MockHelios helios;

    address hubPoolStore;
    uint256 nonce = 0;

    function setUp() public {
        helios = new MockHelios();
        spokePool = new UniversalStorageProof_SpokePool(
            address(helios),
            hubPoolStore,
            address(0),
            7200,
            7200,
            IERC20(address(0)),
            ITokenMessenger(address(0))
        );
    }

    function testReceiveL1State() public {
        // Should be able to call relayRootBundle
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot)
        );
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testReplayProtection() public {
        // Should not be able to receive same L1 state twice, even if block number changes.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        spokePool.receiveL1State(slotKey, value, 100);
        vm.expectRevert(UniversalStorageProof_SpokePool.AlreadyReceived.selector);
        spokePool.receiveL1State(slotKey, value, 101); // block number changes doesn't impact replay protection
    }

    function testVerifiedProofs() public {
        // Checks replay protection mapping is updated as expected.
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        assertFalse(spokePool.verifiedProofs(slotKey));
        spokePool.receiveL1State(slotKey, value, 100);
        assertTrue(spokePool.verifiedProofs(slotKey));
    }

    function testHeliosMissingState() public {
        // Reverts if helios light client state for hubPoolStore, blockNumber, and slot key isn't
        // equal to passed in slot value.
    }

    function testIncorrectTarget() public {
        // Reverts if the target is not the zero address or the spoke pool contract
    }

    function testAdminReceiveL1State() public {
        // Relay message normally to contract:
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", bytes32("test"), bytes32("test2"))
        );
        spokePool.adminReceiveL1State(message);
    }

    function testDelegateCall() public {
        // Can call other functions on the contract
        address originToken = makeAddr("origin");
        uint256 destinationChainId = 111;
        bytes memory message = abi.encodeWithSignature(
            "setEnableRoute(address,uint256,bool)",
            originToken,
            destinationChainId,
            true
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("setEnableRoute(address,uint256,bool)", originToken, destinationChainId, true)
        );
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testBridgeTokensToHubPool_cctp() public {
        // Uses CCTP to send USDC
    }

    function testBridgeTokensToHubPool_default() public {
        // Should revert
    }

    function testRequireAdminSender() public {
        // Calling onlyCrossDomainAdmin functions directly should revert
    }
}
