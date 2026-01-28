// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Vm } from "forge-std/Vm.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";

/**
 * @title SpokePoolUtils
 * @notice Utility library for SpokePool Foundry tests.
 * @dev Contains constants, helper functions for V3RelayData, merkle trees, and EIP-712 signatures.
 */
library SpokePoolUtils {
    using AddressToBytes32 for address;

    // ============ Constants (matching test/evm/hardhat/constants.ts) ============

    uint256 internal constant DESTINATION_CHAIN_ID = 1342;
    uint256 internal constant ORIGIN_CHAIN_ID = 666;
    uint256 internal constant REPAYMENT_CHAIN_ID = 777;
    uint256 internal constant AMOUNT_TO_DEPOSIT = 100 ether;
    uint256 internal constant AMOUNT_TO_RELAY = 25 ether;
    uint256 internal constant AMOUNT_HELD_BY_POOL = 100 ether; // AMOUNT_TO_RELAY * 4
    uint256 internal constant AMOUNT_TO_RETURN = 1 ether;
    uint32 internal constant MAX_REFUNDS_PER_LEAF = 3;

    // Fee percentages (in 1e18 scale)
    int64 internal constant DEPOSIT_RELAYER_FEE_PCT = 0.1e18; // 10%
    int64 internal constant REALIZED_LP_FEE_PCT = 0.1e18; // 10%

    // Time constants
    uint32 internal constant DEFAULT_FILL_DEADLINE_OFFSET = 1000;

    // EIP-712 type hashes
    bytes32 internal constant UPDATE_V3_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint256 depositId,uint256 originChainId,uint256 updatedOutputAmount,bytes32 updatedRecipient,bytes updatedMessage)"
        );

    // ============ V3RelayData Helpers ============

    /**
     * @notice Creates a default V3RelayData struct for testing.
     * @param depositor The depositor address
     * @param recipient The recipient address
     * @param inputToken The input token address
     * @param outputToken The output token address
     * @return relayData The populated V3RelayData struct
     */
    function createDefaultRelayData(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken
    ) internal view returns (V3SpokePoolInterface.V3RelayData memory relayData) {
        relayData = V3SpokePoolInterface.V3RelayData({
            depositor: depositor.toBytes32(),
            recipient: recipient.toBytes32(),
            exclusiveRelayer: bytes32(0),
            inputToken: inputToken.toBytes32(),
            outputToken: outputToken.toBytes32(),
            inputAmount: AMOUNT_TO_DEPOSIT,
            outputAmount: AMOUNT_TO_DEPOSIT,
            originChainId: ORIGIN_CHAIN_ID,
            depositId: 0,
            fillDeadline: uint32(block.timestamp + DEFAULT_FILL_DEADLINE_OFFSET),
            exclusivityDeadline: 0,
            message: ""
        });
    }

    /**
     * @notice Computes the V3 relay hash for a given relay data and destination chain.
     * @dev Matches SpokePool.getV3RelayHash() which does keccak256(abi.encode(relayData, chainId()))
     * @param relayData The V3RelayData struct
     * @param destinationChainId The destination chain ID
     * @return The keccak256 hash of the encoded relay data and destination chain
     */
    function getV3RelayHash(
        V3SpokePoolInterface.V3RelayData memory relayData,
        uint256 destinationChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(relayData, destinationChainId));
    }

    // ============ RelayerRefundLeaf Helpers ============

    /**
     * @notice Creates a RelayerRefundLeaf struct.
     * @param chainId The chain ID for the leaf
     * @param amountToReturn Amount to return to hub pool
     * @param l2TokenAddress The L2 token address
     * @param refundAddresses Array of addresses to refund
     * @param refundAmounts Array of amounts to refund
     * @param leafId The leaf ID in the merkle tree
     * @return leaf The populated RelayerRefundLeaf
     */
    function createRelayerRefundLeaf(
        uint256 chainId,
        uint256 amountToReturn,
        address l2TokenAddress,
        address[] memory refundAddresses,
        uint256[] memory refundAmounts,
        uint32 leafId
    ) internal pure returns (SpokePoolInterface.RelayerRefundLeaf memory leaf) {
        leaf = SpokePoolInterface.RelayerRefundLeaf({
            amountToReturn: amountToReturn,
            chainId: chainId,
            refundAmounts: refundAmounts,
            leafId: leafId,
            l2TokenAddress: l2TokenAddress,
            refundAddresses: refundAddresses
        });
    }

    /**
     * @notice Hashes a RelayerRefundLeaf for merkle tree construction.
     * @param leaf The leaf to hash
     * @return The keccak256 hash of the encoded leaf
     */
    function hashRelayerRefundLeaf(SpokePoolInterface.RelayerRefundLeaf memory leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(leaf));
    }

    /**
     * @notice Builds a single-leaf merkle tree for relayer refunds.
     * @param leaf The relayer refund leaf
     * @return root The merkle root (just the leaf hash for single-leaf trees)
     * @return proof Empty proof array for single-leaf trees
     */
    function buildSingleRelayerRefundTree(
        SpokePoolInterface.RelayerRefundLeaf memory leaf
    ) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = hashRelayerRefundLeaf(leaf);
        proof = new bytes32[](0);
    }

    /**
     * @notice Builds a two-leaf merkle tree for relayer refunds.
     * @param leaf0 The first leaf
     * @param leaf1 The second leaf
     * @return root The merkle root
     * @return proof0 Proof for leaf0
     * @return proof1 Proof for leaf1
     */
    function buildTwoLeafRelayerRefundTree(
        SpokePoolInterface.RelayerRefundLeaf memory leaf0,
        SpokePoolInterface.RelayerRefundLeaf memory leaf1
    ) internal pure returns (bytes32 root, bytes32[] memory proof0, bytes32[] memory proof1) {
        bytes32 hash0 = hashRelayerRefundLeaf(leaf0);
        bytes32 hash1 = hashRelayerRefundLeaf(leaf1);

        // Sort hashes to ensure consistent ordering (smaller hash first)
        if (uint256(hash0) < uint256(hash1)) {
            root = keccak256(abi.encodePacked(hash0, hash1));
        } else {
            root = keccak256(abi.encodePacked(hash1, hash0));
        }

        proof0 = new bytes32[](1);
        proof0[0] = hash1;

        proof1 = new bytes32[](1);
        proof1[0] = hash0;
    }

    // ============ V3SlowFill Helpers ============

    /**
     * @notice Creates a V3SlowFill struct.
     * @param relayData The relay data
     * @param chainId The destination chain ID
     * @param updatedOutputAmount The updated output amount (can be different for slow fills)
     * @return slowFill The populated V3SlowFill struct
     */
    function createV3SlowFill(
        V3SpokePoolInterface.V3RelayData memory relayData,
        uint256 chainId,
        uint256 updatedOutputAmount
    ) internal pure returns (V3SpokePoolInterface.V3SlowFill memory slowFill) {
        slowFill = V3SpokePoolInterface.V3SlowFill({
            relayData: relayData,
            chainId: chainId,
            updatedOutputAmount: updatedOutputAmount
        });
    }

    /**
     * @notice Hashes a V3SlowFill leaf for merkle tree construction.
     * @param slowFill The slow fill to hash
     * @return The keccak256 hash of the encoded slow fill
     */
    function hashV3SlowFillLeaf(V3SpokePoolInterface.V3SlowFill memory slowFill) internal pure returns (bytes32) {
        return keccak256(abi.encode(slowFill));
    }

    /**
     * @notice Builds a single-leaf merkle tree for V3 slow fills.
     * @param slowFill The slow fill leaf
     * @return root The merkle root
     * @return proof Empty proof array
     */
    function buildSingleV3SlowFillTree(
        V3SpokePoolInterface.V3SlowFill memory slowFill
    ) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = hashV3SlowFillLeaf(slowFill);
        proof = new bytes32[](0);
    }

    // ============ EIP-712 Signature Utilities ============

    /**
     * @notice Signs an UpdateV3Deposit message using EIP-712.
     * @dev Uses Foundry's vm.sign to create the signature.
     * @param vm The Foundry VM instance
     * @param privateKey The signer's private key
     * @param depositId The deposit ID to update
     * @param originChainId The origin chain ID
     * @param updatedOutputAmount The new output amount
     * @param updatedRecipient The new recipient (as bytes32)
     * @param updatedMessage The new message
     * @return signature The packed signature (r, s, v)
     */
    function signUpdateV3Deposit(
        Vm vm,
        uint256 privateKey,
        uint256 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes memory updatedMessage
    ) internal pure returns (bytes memory signature) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
                keccak256("ACROSS-V2"),
                keccak256("1.0.0"),
                originChainId
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                UPDATE_V3_DEPOSIT_DETAILS_HASH,
                depositId,
                originChainId,
                updatedOutputAmount,
                updatedRecipient,
                keccak256(updatedMessage)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        // Pack signature as r, s, v (65 bytes total)
        signature = abi.encodePacked(r, s, v);
    }

    /**
     * @notice Signs an UpdateV3Deposit message with address recipient.
     * @param vm The Foundry VM instance
     * @param privateKey The signer's private key
     * @param depositId The deposit ID to update
     * @param originChainId The origin chain ID
     * @param updatedOutputAmount The new output amount
     * @param updatedRecipient The new recipient address
     * @param updatedMessage The new message
     * @return signature The packed signature
     */
    function signUpdateV3DepositWithAddress(
        Vm vm,
        uint256 privateKey,
        uint256 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes memory updatedMessage
    ) internal pure returns (bytes memory signature) {
        return
            signUpdateV3Deposit(
                vm,
                privateKey,
                depositId,
                originChainId,
                updatedOutputAmount,
                updatedRecipient.toBytes32(),
                updatedMessage
            );
    }

    // ============ Utility Functions ============

    /**
     * @notice Returns an empty bytes32 array (for empty merkle proofs).
     */
    function emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /**
     * @notice Creates a random bytes32 value for testing.
     * @param seed A seed value for deterministic randomness
     * @return A pseudo-random bytes32
     */
    function createRandomBytes32(uint256 seed) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("random", seed));
    }
}
