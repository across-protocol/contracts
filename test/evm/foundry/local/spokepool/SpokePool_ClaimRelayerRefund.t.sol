// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { ExpandedERC20WithBlacklist } from "../../../../../contracts/test/ExpandedERC20WithBlacklist.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { AddressToBytes32 } from "../../../../../contracts/libraries/AddressConverters.sol";

contract SpokePoolClaimRelayerRefundTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool public spokePool;
    ExpandedERC20WithBlacklist public destErc20;
    WETH9 public weth;

    address public owner;
    address public relayer;
    address public rando;

    uint256 public constant AMOUNT_TO_RELAY = 25e18;
    uint256 public constant AMOUNT_HELD_BY_POOL = AMOUNT_TO_RELAY * 4;
    uint256 public constant AMOUNT_TO_RETURN = 1e18;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;

    function setUp() public {
        owner = makeAddr("owner");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");

        weth = new WETH9();

        // Deploy destErc20 with blacklist functionality
        destErc20 = new ExpandedERC20WithBlacklist("L2 USD Coin", "L2 USDC", 18);
        // Add this test contract as minter (Minter role = 1)
        destErc20.addMember(1, address(this));

        // Deploy SpokePool via proxy
        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(MockSpokePool.initialize, (0, owner, owner)))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(DESTINATION_CHAIN_ID);
        vm.stopPrank();

        // Seed the SpokePool with tokens
        destErc20.mint(address(spokePool), AMOUNT_HELD_BY_POOL);
    }

    function testBlacklistOperatesAsExpected() public {
        // Transfer tokens to relayer before blacklisting works as expected
        destErc20.mint(owner, AMOUNT_TO_RELAY);

        vm.prank(owner);
        destErc20.transfer(relayer, AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(relayer), AMOUNT_TO_RELAY);

        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Attempt to transfer tokens to the blacklisted relayer should revert
        destErc20.mint(owner, AMOUNT_TO_RELAY);
        vm.prank(owner);
        vm.expectRevert("Recipient is blacklisted");
        destErc20.transfer(relayer, AMOUNT_TO_RELAY);
    }

    function testDistributeRelayerRefundsHandlesBlacklistedAddresses() public {
        // No starting relayer liability
        assertEq(spokePool.getRelayerRefund(address(destErc20), relayer), 0);
        assertEq(destErc20.balanceOf(rando), 0);
        assertEq(destErc20.balanceOf(relayer), 0);

        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Distribute relayer refunds - some refunds go to blacklisted address, some to non-blacklisted
        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = AMOUNT_TO_RELAY;
        refundAmounts[1] = AMOUNT_TO_RELAY;

        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        vm.prank(owner);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            AMOUNT_TO_RETURN,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // Blacklisted relayer should have their refund tracked in relayerRefund mapping
        assertEq(spokePool.getRelayerRefund(address(destErc20), relayer), AMOUNT_TO_RELAY);
        // Non-blacklisted address should receive tokens directly
        assertEq(destErc20.balanceOf(rando), AMOUNT_TO_RELAY);
        // Blacklisted relayer should not have received tokens
        assertEq(destErc20.balanceOf(relayer), 0);
    }

    function testBlacklistedRelayerCanClaimRefundToNewAddress() public {
        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Distribute relayer refunds to blacklisted address
        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = AMOUNT_TO_RELAY;

        address[] memory refundAddresses = new address[](1);
        refundAddresses[0] = relayer;

        vm.prank(owner);
        spokePool.distributeRelayerRefunds(
            DESTINATION_CHAIN_ID,
            AMOUNT_TO_RETURN,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // Attempting to claim to the blacklisted address should fail
        vm.prank(relayer);
        vm.expectRevert("Recipient is blacklisted");
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), relayer.toBytes32());

        // Claiming to a different (non-blacklisted) address should succeed
        assertEq(destErc20.balanceOf(rando), 0);

        vm.prank(relayer);
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), rando.toBytes32());

        assertEq(destErc20.balanceOf(rando), AMOUNT_TO_RELAY);
    }
}
