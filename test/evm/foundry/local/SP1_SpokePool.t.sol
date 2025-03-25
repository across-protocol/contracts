// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SP1_SpokePool, IHelios } from "../../../../contracts/SP1_SpokePool.sol";
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

    function GENESIS_TIME() external pure returns (uint256) {
        return 0;
    }

    /// @notice Seconds per slot in the beacon chain
    function SECONDS_PER_SLOT() external pure returns (uint256) {
        return 1;
    }

    /// @notice Maps from a slot to a beacon block header root
    function headers(uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract SP1SpokePoolTest is Test {
    SP1_SpokePool spokePool;
    MockHelios helios;

    address hubPoolStore;
    uint256 nonce = 0;

    function setUp() public {
        helios = new MockHelios();
        spokePool = new SP1_SpokePool(
            address(helios),
            bytes32(0),
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
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        bytes32 slotKey = keccak256(abi.encode(address(spokePool), message, nonce));
        bytes memory value = abi.encode(address(spokePool), message);
        helios.updateStorageSlot(slotKey, keccak256(value));
        spokePool.receiveL1State(slotKey, value, 100);
        vm.expectRevert(SP1_SpokePool.AlreadyReceived.selector);
        spokePool.receiveL1State(slotKey, value, 100);
    }

    function testVerifyProof() public {
        // Reverts if sp1 verifyProof fails
    }

    function testIncorrectContractAddress() public {
        // Reverts if the contract address in publicValues is not the hubPoolStore
    }

    function testHeliosProof() public {
        // Reverts if helios light client state doesn't match with publicValues
    }

    function testIncorrectTarget() public {
        // Reverts if the target in publicValues is not the zero address or this contract
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
}
