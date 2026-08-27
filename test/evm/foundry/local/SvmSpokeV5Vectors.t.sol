// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice EVM-side conformance checks for the SVM V5 adapter's cross-VM hash and signature fixtures.
contract SvmSpokeV5VectorsTest is Test {
    using ECDSA for bytes32;

    string internal fixture;

    function setUp() public {
        fixture = vm.readFile("programs/svm-spoke/fixtures/v5_adapter_v1.json");
    }

    function testDepositIdVector() public view {
        bytes32 submitter = vm.parseJsonBytes32(fixture, ".context.submitter");
        bytes32 pathId = vm.parseJsonBytes32(fixture, ".context.pathId");
        uint256 nonce = vm.parseUint(vm.parseJsonString(fixture, ".deposit.depositNonce"));
        bytes32 syntheticNonce = keccak256(abi.encodePacked(submitter, pathId, nonce));
        assertEq(syntheticNonce, vm.parseJsonBytes32(fixture, ".deposit.syntheticNonce"));

        bytes32 depositId = keccak256(
            abi.encodePacked(
                vm.parseJsonBytes32(fixture, ".programs.gatewayBytes"),
                vm.parseJsonBytes32(fixture, ".deposit.depositor"),
                syntheticNonce
            )
        );
        assertEq(depositId, vm.parseJsonBytes32(fixture, ".deposit.depositId"));
    }

    function testJitSignatureVector() public view {
        bytes32 nameHash = keccak256("ACXV.AcrossDepositDelegateAdapter.V1");
        assertEq(nameHash, vm.parseJsonBytes32(fixture, ".jit.nameHash"));
        bytes32 domain = keccak256(abi.encode(nameHash, vm.parseJsonBytes32(fixture, ".programs.gatewayBytes")));
        assertEq(domain, vm.parseJsonBytes32(fixture, ".jit.domain"));

        bytes32 digest = _jitDigest(domain);
        assertEq(digest, vm.parseJsonBytes32(fixture, ".jit.digest"));
        assertEq(
            digest.recover(vm.parseJsonBytes(fixture, ".jit.signature")),
            vm.parseJsonAddress(fixture, ".jit.authority")
        );
    }

    function testHighSSignatureVectorIsRejected() public view {
        (, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
            vm.parseJsonBytes32(fixture, ".jit.digest"),
            vm.parseJsonBytes(fixture, ".jit.highSSignature")
        );
        assertEq(uint256(err), uint256(ECDSA.RecoverError.InvalidSignatureS));
    }

    function testGatewayDiscriminatorVector() public view {
        bytes memory discriminator = vm.parseJsonBytes(fixture, ".dispatch.discriminator");
        assertEq(bytes8(sha256("global:adapter_execute_across_v5")), bytes8(discriminator));
    }

    function _jitDigest(bytes32 domain) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    domain,
                    vm.parseJsonBytes32(fixture, ".context.pathId"),
                    vm.parseUint(vm.parseJsonString(fixture, ".deposit.depositNonce")),
                    vm.parseJsonBytes32(fixture, ".jit.newOutputAmount"),
                    vm.parseJsonBytes32(fixture, ".jit.newExclusiveRelayer")
                )
            );
    }
}
