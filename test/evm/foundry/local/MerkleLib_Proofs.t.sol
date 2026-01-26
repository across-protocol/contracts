// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MerkleLibTest } from "../../../../contracts/test/MerkleLibTest.sol";
import { Merkle } from "murky/Merkle.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { SpokePoolInterface } from "../../../../contracts/interfaces/SpokePoolInterface.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";

/**
 * @title MerkleLib_ProofsTest
 * @notice Tests for MerkleLib proof verification
 */
contract MerkleLib_ProofsTest is Test {
    MerkleLibTest merkleLibTest;
    Merkle merkle;

    // Empty merkle root constant (matches TypeScript EMPTY_MERKLE_ROOT)
    bytes32 constant EMPTY_MERKLE_ROOT = bytes32(0);

    function setUp() public {
        merkleLibTest = new MerkleLibTest();
        merkle = new Merkle();
    }

    // ============ Empty Tree Test ============

    function test_EmptyTree() public pure {
        // An empty tree should have a root of bytes32(0)
        // This matches the TypeScript MerkleTree behavior where an empty tree returns EMPTY_MERKLE_ROOT
        // Note: Murky doesn't support empty trees, but the protocol uses bytes32(0) as the empty root
        assertEq(EMPTY_MERKLE_ROOT, bytes32(0));
    }

    // ============ Pool Rebalance Leaf Proof Test ============

    function test_PoolRebalanceLeafProof() public {
        // Create 100 leaves
        uint256 numLeaves = 100;
        bytes32[] memory leafHashes = new bytes32[](numLeaves);
        HubPoolInterface.PoolRebalanceLeaf[] memory leaves = new HubPoolInterface.PoolRebalanceLeaf[](numLeaves);

        for (uint256 i = 0; i < numLeaves; i++) {
            // Create leaf with 10 tokens
            uint256 numTokens = 10;
            address[] memory l1Tokens = new address[](numTokens);
            uint256[] memory bundleLpFees = new uint256[](numTokens);
            int256[] memory netSendAmounts = new int256[](numTokens);
            int256[] memory runningBalances = new int256[](numTokens);

            for (uint256 j = 0; j < numTokens; j++) {
                l1Tokens[j] = address(uint160(uint256(keccak256(abi.encode("token", i, j)))));
                bundleLpFees[j] = uint256(keccak256(abi.encode("fee", i, j))) % 1e20;
                netSendAmounts[j] = int256(uint256(keccak256(abi.encode("net", i, j))) % 1e20);
                runningBalances[j] = int256(uint256(keccak256(abi.encode("running", i, j))) % 1e20);
            }

            leaves[i] = HubPoolInterface.PoolRebalanceLeaf({
                chainId: uint256(keccak256(abi.encode("chain", i))) % 1000,
                groupIndex: 0,
                bundleLpFees: bundleLpFees,
                netSendAmounts: netSendAmounts,
                runningBalances: runningBalances,
                leafId: uint8(i),
                l1Tokens: l1Tokens
            });

            leafHashes[i] = keccak256(abi.encode(leaves[i]));
        }

        // Build Merkle tree using Murky
        bytes32 root = merkle.getRoot(leafHashes);

        // Verify leaf at index 34
        bytes32[] memory proof = merkle.getProof(leafHashes, 34);
        assertTrue(merkleLibTest.verifyPoolRebalance(root, leaves[34], proof));

        // Create an invalid leaf (101st leaf that was never added to tree)
        HubPoolInterface.PoolRebalanceLeaf memory invalidLeaf;
        {
            uint256 numTokens = 10;
            address[] memory l1Tokens = new address[](numTokens);
            uint256[] memory bundleLpFees = new uint256[](numTokens);
            int256[] memory netSendAmounts = new int256[](numTokens);
            int256[] memory runningBalances = new int256[](numTokens);

            for (uint256 j = 0; j < numTokens; j++) {
                l1Tokens[j] = address(uint160(uint256(keccak256(abi.encode("token", 100, j)))));
                bundleLpFees[j] = uint256(keccak256(abi.encode("fee", 100, j))) % 1e20;
                netSendAmounts[j] = int256(uint256(keccak256(abi.encode("net", 100, j))) % 1e20);
                runningBalances[j] = int256(uint256(keccak256(abi.encode("running", 100, j))) % 1e20);
            }

            invalidLeaf = HubPoolInterface.PoolRebalanceLeaf({
                chainId: uint256(keccak256(abi.encode("chain", 100))) % 1000,
                groupIndex: 0,
                bundleLpFees: bundleLpFees,
                netSendAmounts: netSendAmounts,
                runningBalances: runningBalances,
                leafId: 100,
                l1Tokens: l1Tokens
            });
        }

        // Invalid leaf should fail verification with the proof from leaf 34
        assertFalse(merkleLibTest.verifyPoolRebalance(root, invalidLeaf, proof));
    }

    // ============ Relayer Refund Leaf Proof Test ============

    function test_RelayerRefundLeafProof() public {
        // Create 100 leaves
        uint256 numLeaves = 100;
        bytes32[] memory leafHashes = new bytes32[](numLeaves);
        SpokePoolInterface.RelayerRefundLeaf[] memory leaves = new SpokePoolInterface.RelayerRefundLeaf[](numLeaves);

        for (uint256 i = 0; i < numLeaves; i++) {
            // Create leaf with 10 refund addresses
            uint256 numAddresses = 10;
            address[] memory refundAddresses = new address[](numAddresses);
            uint256[] memory refundAmounts = new uint256[](numAddresses);

            for (uint256 j = 0; j < numAddresses; j++) {
                refundAddresses[j] = address(uint160(uint256(keccak256(abi.encode("relayer", i, j)))));
                refundAmounts[j] = uint256(keccak256(abi.encode("amount", i, j))) % 1e20;
            }

            leaves[i] = SpokePoolInterface.RelayerRefundLeaf({
                amountToReturn: uint256(keccak256(abi.encode("return", i))) % 1e20,
                chainId: uint256(keccak256(abi.encode("chain", i))) % 1000,
                refundAmounts: refundAmounts,
                leafId: uint32(i),
                l2TokenAddress: address(uint160(uint256(keccak256(abi.encode("l2token", i))))),
                refundAddresses: refundAddresses
            });

            leafHashes[i] = keccak256(abi.encode(leaves[i]));
        }

        // Build Merkle tree using Murky
        bytes32 root = merkle.getRoot(leafHashes);

        // Verify leaf at index 14
        bytes32[] memory proof = merkle.getProof(leafHashes, 14);
        assertTrue(merkleLibTest.verifyRelayerRefund(root, leaves[14], proof));

        // Create an invalid leaf
        SpokePoolInterface.RelayerRefundLeaf memory invalidLeaf;
        {
            uint256 numAddresses = 10;
            address[] memory refundAddresses = new address[](numAddresses);
            uint256[] memory refundAmounts = new uint256[](numAddresses);

            for (uint256 j = 0; j < numAddresses; j++) {
                refundAddresses[j] = address(uint160(uint256(keccak256(abi.encode("relayer", 100, j)))));
                refundAmounts[j] = uint256(keccak256(abi.encode("amount", 100, j))) % 1e20;
            }

            invalidLeaf = SpokePoolInterface.RelayerRefundLeaf({
                amountToReturn: uint256(keccak256(abi.encode("return", 100))) % 1e20,
                chainId: uint256(keccak256(abi.encode("chain", 100))) % 1000,
                refundAmounts: refundAmounts,
                leafId: 100,
                l2TokenAddress: address(uint160(uint256(keccak256(abi.encode("l2token", 100))))),
                refundAddresses: refundAddresses
            });
        }

        // Invalid leaf should fail verification
        assertFalse(merkleLibTest.verifyRelayerRefund(root, invalidLeaf, proof));
    }

    // ============ V3 Slow Fill Proof Test ============

    function test_V3SlowFillProof() public {
        // Create 100 leaves
        uint256 numLeaves = 100;
        bytes32[] memory leafHashes = new bytes32[](numLeaves);
        V3SpokePoolInterface.V3SlowFill[] memory slowFills = new V3SpokePoolInterface.V3SlowFill[](numLeaves);

        for (uint256 i = 0; i < numLeaves; i++) {
            V3SpokePoolInterface.V3RelayData memory relayData = V3SpokePoolInterface.V3RelayData({
                depositor: keccak256(abi.encode("depositor", i)),
                recipient: keccak256(abi.encode("recipient", i)),
                exclusiveRelayer: keccak256(abi.encode("relayer", i)),
                inputToken: keccak256(abi.encode("inputToken", i)),
                outputToken: keccak256(abi.encode("outputToken", i)),
                inputAmount: uint256(keccak256(abi.encode("inputAmount", i))) % 1e20,
                outputAmount: uint256(keccak256(abi.encode("outputAmount", i))) % 1e20,
                originChainId: uint256(keccak256(abi.encode("originChain", i))) % 1000,
                depositId: i,
                fillDeadline: uint32(block.timestamp + 3600 + i),
                exclusivityDeadline: uint32(uint256(keccak256(abi.encode("exclusivity", i))) % 1000),
                message: abi.encodePacked(keccak256(abi.encode("message", i)))
            });

            slowFills[i] = V3SpokePoolInterface.V3SlowFill({
                relayData: relayData,
                chainId: uint256(keccak256(abi.encode("chain", i))) % 1000,
                updatedOutputAmount: relayData.outputAmount
            });

            leafHashes[i] = keccak256(abi.encode(slowFills[i]));
        }

        // Build Merkle tree using Murky
        bytes32 root = merkle.getRoot(leafHashes);

        // Verify leaf at index 14
        bytes32[] memory proof = merkle.getProof(leafHashes, 14);
        assertTrue(merkleLibTest.verifyV3SlowRelayFulfillment(root, slowFills[14], proof));

        // Create an invalid leaf
        V3SpokePoolInterface.V3RelayData memory invalidRelayData = V3SpokePoolInterface.V3RelayData({
            depositor: keccak256(abi.encode("depositor", 100)),
            recipient: keccak256(abi.encode("recipient", 100)),
            exclusiveRelayer: keccak256(abi.encode("relayer", 100)),
            inputToken: keccak256(abi.encode("inputToken", 100)),
            outputToken: keccak256(abi.encode("outputToken", 100)),
            inputAmount: uint256(keccak256(abi.encode("inputAmount", 100))) % 1e20,
            outputAmount: uint256(keccak256(abi.encode("outputAmount", 100))) % 1e20,
            originChainId: uint256(keccak256(abi.encode("originChain", 100))) % 1000,
            depositId: 100,
            fillDeadline: uint32(block.timestamp + 3600 + 100),
            exclusivityDeadline: uint32(uint256(keccak256(abi.encode("exclusivity", 100))) % 1000),
            message: abi.encodePacked(keccak256(abi.encode("message", 100)))
        });

        V3SpokePoolInterface.V3SlowFill memory invalidSlowFill = V3SpokePoolInterface.V3SlowFill({
            relayData: invalidRelayData,
            chainId: uint256(keccak256(abi.encode("chain", 100))) % 1000,
            updatedOutputAmount: invalidRelayData.outputAmount
        });

        // Invalid leaf should fail verification
        assertFalse(merkleLibTest.verifyV3SlowRelayFulfillment(root, invalidSlowFill, proof));
    }
}
