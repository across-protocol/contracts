// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

// Define a minimal interface for USDT. Note USDT does NOT return anything after a transfer.
interface IUSDT {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external;

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external;

    function addBlackList(address _evilUser) external;

    function getBlackListStatus(address _evilUser) external view returns (bool);
}

// Define a minimal interface for USDC. Note USDC returns a boolean after a transfer.
interface IUSDC {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function blacklist(address _account) external;

    function isBlacklisted(address _account) external view returns (bool);
}

contract MockSpokePoolTest is Test {
    MockSpokePool spokePool;
    IUSDT usdt;
    IUSDC usdc;
    using AddressToBytes32 for address;

    address largeUSDTAccount = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1;
    address largeUSDCAccount = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    uint256 seedAmount = 10_000 * 10**6;

    address recipient1 = address(0x6969691111111420);
    address recipient2 = address(0x6969692222222420);

    function setUp() public {
        spokePool = new MockSpokePool(address(0x123));
        // Create an instance of USDT & USDCusing its mainnet address
        usdt = IUSDT(address(0xdAC17F958D2ee523a2206206994597C13D831ec7));
        usdc = IUSDC(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

        // Impersonate a large USDT & USDC holders and send tokens to spokePool contract.
        assertTrue(usdt.balanceOf(largeUSDTAccount) > seedAmount, "Large USDT holder has less USDT than expected");
        assertTrue(usdc.balanceOf(largeUSDCAccount) > seedAmount, "Large USDC holder has less USDC than expected");

        vm.prank(largeUSDTAccount);
        usdt.transfer(address(spokePool), seedAmount);
        assertEq(usdt.balanceOf(address(spokePool)), seedAmount, "Seed transfer failed");

        vm.prank(largeUSDCAccount);
        usdc.transfer(address(spokePool), seedAmount);
        assertEq(usdc.balanceOf(address(spokePool)), seedAmount, "USDC seed transfer failed");
    }

    function testStandardRefundsWorks() public {
        // Test USDT
        assertEq(usdt.balanceOf(recipient1), 0, "Recipient should start with 0 USDT balance");
        assertEq(usdt.balanceOf(address(spokePool)), seedAmount, "SpokePool should have seed USDT balance");

        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = 420 * 10**6;

        address[] memory refundAddresses = new address[](1);
        refundAddresses[0] = recipient1;
        spokePool.distributeRelayerRefunds(1, 0, refundAmounts, 0, address(usdt), refundAddresses);

        assertEq(usdt.balanceOf(recipient1), refundAmounts[0], "Recipient should have received refund");
        assertEq(usdt.balanceOf(address(spokePool)), seedAmount - refundAmounts[0], "SpokePool bal should drop");

        // Test USDC
        assertEq(usdc.balanceOf(recipient1), 0, "Recipient should start with 0 USDC balance");
        assertEq(usdc.balanceOf(address(spokePool)), seedAmount, "SpokePool should have seed USDC balance");

        spokePool.distributeRelayerRefunds(1, 0, refundAmounts, 0, address(usdc), refundAddresses);

        assertEq(usdc.balanceOf(recipient1), refundAmounts[0], "Recipient should have received refund");
        assertEq(usdc.balanceOf(address(spokePool)), seedAmount - refundAmounts[0], "SpokePool bal should drop");
    }

    function testSomeRecipientsBlacklistedDoesNotBlockTheWholeRefundUsdt() public {
        // Note that USDT does NOT block blacklisted recipients, only blacklisted senders. This means that even
        // if a recipient is blacklisted the bundle payment should still work to them, even though they then cant
        // send the tokens after the fact.
        assertEq(usdt.getBlackListStatus(recipient1), false, "Recipient1 should not be blacklisted");
        vm.prank(0xC6CDE7C39eB2f0F0095F41570af89eFC2C1Ea828); // USDT owner.
        usdt.addBlackList(recipient1);
        assertEq(usdt.getBlackListStatus(recipient1), true, "Recipient1 should be blacklisted");

        assertEq(usdt.balanceOf(recipient1), 0, "Recipient1 should start with 0 USDT balance");
        assertEq(usdt.balanceOf(recipient2), 0, "Recipient2 should start with 0 USDT balance");

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = 420 * 10**6;
        refundAmounts[1] = 69 * 10**6;

        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = recipient1;
        refundAddresses[1] = recipient2;
        spokePool.distributeRelayerRefunds(1, 0, refundAmounts, 0, address(usdt), refundAddresses);

        assertEq(usdt.balanceOf(recipient1), refundAmounts[0], "Recipient1 should have received their refund");
        assertEq(usdt.balanceOf(recipient2), refundAmounts[1], "Recipient2 should have received their refund");

        assertEq(spokePool.getRelayerRefund(address(usdt), recipient1), 0);
        assertEq(spokePool.getRelayerRefund(address(usdt), recipient2), 0);
    }

    function testSomeRecipientsBlacklistedDoesNotBlockTheWholeRefundUsdc() public {
        // USDC blacklist blocks both the sender and recipient. Therefore if we a recipient within a bundle is
        // blacklisted, they should be credited for the refund amount that can be claimed later to a new address.
        assertEq(usdc.isBlacklisted(recipient1), false, "Recipient1 should not be blacklisted");
        vm.prank(0x10DF6B6fe66dd319B1f82BaB2d054cbb61cdAD2e); // USDC blacklister
        usdc.blacklist(recipient1);
        assertEq(usdc.isBlacklisted(recipient1), true, "Recipient1 should be blacklisted");

        assertEq(usdc.balanceOf(recipient1), 0, "Recipient1 should start with 0 USDc balance");
        assertEq(usdc.balanceOf(recipient2), 0, "Recipient2 should start with 0 USDc balance");

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = 420 * 10**6;
        refundAmounts[1] = 69 * 10**6;

        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = recipient1;
        refundAddresses[1] = recipient2;
        spokePool.distributeRelayerRefunds(1, 0, refundAmounts, 0, address(usdc), refundAddresses);

        assertEq(usdc.balanceOf(recipient1), 0, "Recipient1 should have 0 refund as blacklisted");
        assertEq(usdc.balanceOf(recipient2), refundAmounts[1], "Recipient2 should have received their refund");

        assertEq(spokePool.getRelayerRefund(address(usdc), recipient1), refundAmounts[0]);
        assertEq(spokePool.getRelayerRefund(address(usdc), recipient2), 0);

        // Now, blacklisted recipient should be able to claim refund to a new address.
        address newRecipient = address(0x6969693333333420);
        vm.prank(recipient1);
        spokePool.claimRelayerRefund(address(usdc).toBytes32(), newRecipient.toBytes32());
        assertEq(usdc.balanceOf(newRecipient), refundAmounts[0], "New recipient should have received relayer2 refund");
        assertEq(spokePool.getRelayerRefund(address(usdt), recipient1), 0);
    }

    function toBytes32(address _address) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_address)));
    }
}
