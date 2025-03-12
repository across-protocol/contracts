// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SP1_SpokePool, IHelios, ISP1Verifier } from "../../../../contracts/SP1_SpokePool.sol";

contract MockHelios is IHelios {
    function executionStateRoots(uint256) external pure override returns (bytes32) {
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
            7200
        );
    }

    function testReceiveL1State() public {
        // Should be able to call relayRootBundle
        bytes32 refundRoot = bytes32("test");
        bytes32 slowRelayRoot = bytes32("test2");
        bytes memory message = abi.encodeWithSignature("relayRootBundle(bytes32,bytes32)", refundRoot, slowRelayRoot);
        SP1_SpokePool.Data memory data = SP1_SpokePool.Data({ target: address(spokePool), data: message, nonce: 0 });
        SP1_SpokePool.ContractPublicValues memory publicValues = SP1_SpokePool.ContractPublicValues({
            stateRoot: bytes32(0),
            contractAddress: hubPoolStore,
            storageKey: "",
            storageValue: abi.encode(data)
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
        SP1_SpokePool.Data memory data = SP1_SpokePool.Data({ target: address(spokePool), data: message, nonce: 0 });
        SP1_SpokePool.ContractPublicValues memory publicValues = SP1_SpokePool.ContractPublicValues({
            stateRoot: bytes32(0),
            contractAddress: hubPoolStore,
            storageKey: "",
            storageValue: abi.encode(data)
        });
        spokePool.receiveL1State(abi.encode(publicValues), "", 100);
        vm.expectRevert(SP1_SpokePool.AlreadyReceived.selector);
        spokePool.receiveL1State(abi.encode(publicValues), "", 100);
    }
}
