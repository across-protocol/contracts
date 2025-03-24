// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SP1_SpokePool, IHelios, ISP1Verifier } from "../../../../contracts/SP1_SpokePool.sol";
import "../../../../contracts/libraries/CircleCCTPAdapter.sol";

contract MockHelios is IHelios {
    bytes32 public constant MOCK_STORAGE_SLOT = bytes32("mockStorageSlot");

    function getStorageSlot(
        uint256,
        address,
        bytes32
    ) external pure returns (bytes32) {
        return MOCK_STORAGE_SLOT;
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

contract MockSP1Verifier is ISP1Verifier {
    function verifyProof(
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure override {}
}

contract SP1SpokePoolTest is Test {
    SP1_SpokePool spokePool;
    MockHelios helios;
    MockSP1Verifier verifier;

    address hubPoolStore;
    uint256 nonce = 0;

    function setUp() public {
        helios = new MockHelios();
        verifier = new MockSP1Verifier();
        spokePool = new SP1_SpokePool(
            address(verifier),
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
        SP1_SpokePool.ContractPublicValues memory publicValues = SP1_SpokePool.ContractPublicValues({
            contractAddress: hubPoolStore,
            slotKey: keccak256(abi.encode(address(spokePool), message, nonce)),
            value: abi.encode(address(spokePool), message),
            slotValueHash: helios.MOCK_STORAGE_SLOT()
        });
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot)
        );
        spokePool.receiveL1State(abi.encode(publicValues), "", 100);
    }

    function testReplayProtection() public {
        bytes memory message = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            bytes32("test"),
            bytes32("test2")
        );
        SP1_SpokePool.ContractPublicValues memory publicValues = SP1_SpokePool.ContractPublicValues({
            contractAddress: hubPoolStore,
            slotKey: keccak256(abi.encode(address(spokePool), message, nonce)),
            value: abi.encode(address(spokePool), message),
            slotValueHash: helios.MOCK_STORAGE_SLOT()
        });
        spokePool.receiveL1State(abi.encode(publicValues), "", 100);
        vm.expectRevert(SP1_SpokePool.AlreadyReceived.selector);
        spokePool.receiveL1State(abi.encode(publicValues), "", 100);
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
        SP1_SpokePool.ContractPublicValues memory publicValues = SP1_SpokePool.ContractPublicValues({
            contractAddress: hubPoolStore,
            slotKey: keccak256(abi.encode(address(spokePool), message, nonce)),
            value: abi.encode(address(spokePool), message),
            slotValueHash: helios.MOCK_STORAGE_SLOT()
        });
        vm.expectCall(
            address(spokePool),
            abi.encodeWithSignature("setEnableRoute(address,uint256,bool)", originToken, destinationChainId, true)
        );
        spokePool.receiveL1State(abi.encode(publicValues), "", 100);
    }
}
