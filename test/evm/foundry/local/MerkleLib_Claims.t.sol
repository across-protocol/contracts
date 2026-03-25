// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MerkleLibTest } from "../../../../contracts/test/MerkleLibTest.sol";

/**
 * @title MerkleLib_ClaimsTest
 * @notice Tests for MerkleLib bitmap claim tracking
 */
contract MerkleLib_ClaimsTest is Test {
    MerkleLibTest merkleLibTest;

    function setUp() public {
        merkleLibTest = new MerkleLibTest();
    }

    // ============ 2D Bitmap Tests ============

    function test_2D_SetAndReadSingleClaim() public {
        // Index 1500 should map to slot 5, bit 220
        // 1500 / 256 = 5 (slot)
        // 1500 % 256 = 220 (bit)

        assertFalse(merkleLibTest.isClaimed(1500));

        merkleLibTest.setClaimed(1500);

        assertTrue(merkleLibTest.isClaimed(1500));

        // Verify the correct bit is set: 2^220
        assertEq(merkleLibTest.claimedBitMap(5), 1 << 220);
    }

    function test_2D_SetAndReadMultipleClaims() public {
        // Test consecutive indices in the same slot
        assertFalse(merkleLibTest.isClaimed(1499));
        assertFalse(merkleLibTest.isClaimed(1500));
        assertFalse(merkleLibTest.isClaimed(1501));

        merkleLibTest.setClaimed(1499);
        merkleLibTest.setClaimed(1500);
        merkleLibTest.setClaimed(1501);

        assertTrue(merkleLibTest.isClaimed(1499));
        assertTrue(merkleLibTest.isClaimed(1500));
        assertTrue(merkleLibTest.isClaimed(1501));
        assertFalse(merkleLibTest.isClaimed(1502)); // Was not set

        // Verify all bits are set correctly in slot 5
        // 1499 % 256 = 219, 1500 % 256 = 220, 1501 % 256 = 221
        uint256 expectedBitmap = (1 << 219) | (1 << 220) | (1 << 221);
        assertEq(merkleLibTest.claimedBitMap(5), expectedBitmap);
    }

    // ============ 1D Bitmap Tests ============

    function test_1D_SetAndReadSingleClaim() public {
        assertFalse(merkleLibTest.isClaimed1D(150));

        merkleLibTest.setClaimed1D(150);

        assertTrue(merkleLibTest.isClaimed1D(150));

        // Verify the correct bit is set: 2^150
        assertEq(merkleLibTest.claimedBitMap1D(), 1 << 150);
    }

    function test_1D_SetAndReadMultipleClaims() public {
        assertFalse(merkleLibTest.isClaimed1D(149));
        assertFalse(merkleLibTest.isClaimed1D(150));
        assertFalse(merkleLibTest.isClaimed1D(151));

        merkleLibTest.setClaimed1D(149);
        merkleLibTest.setClaimed1D(150);
        merkleLibTest.setClaimed1D(151);

        assertTrue(merkleLibTest.isClaimed1D(149));
        assertTrue(merkleLibTest.isClaimed1D(150));
        assertTrue(merkleLibTest.isClaimed1D(151));
        assertFalse(merkleLibTest.isClaimed1D(152)); // Was not set

        // Verify all bits are set
        uint256 expectedBitmap = (1 << 149) | (1 << 150) | (1 << 151);
        assertEq(merkleLibTest.claimedBitMap1D(), expectedBitmap);
    }

    function test_1D_OverflowingMaxIndexHandledCorrectly() public {
        assertFalse(merkleLibTest.isClaimed1D(150));
        merkleLibTest.setClaimed1D(150);
        assertTrue(merkleLibTest.isClaimed1D(150));

        // Note: In Solidity, we can't call setClaimed1D(256) or isClaimed1D(256) because
        // the function signature takes uint8, which only goes up to 255.
        // The Solidity compiler will reject any value >= 256 at compile time.

        // Should be able to set right below the max (255)
        assertFalse(merkleLibTest.isClaimed1D(255));
        merkleLibTest.setClaimed1D(255);
        assertTrue(merkleLibTest.isClaimed1D(255));
    }
}
