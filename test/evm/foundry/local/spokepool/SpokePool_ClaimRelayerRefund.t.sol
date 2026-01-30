// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { ExpandedERC20WithBlacklist } from "../../../../../contracts/test/ExpandedERC20WithBlacklist.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SpokePoolUtils } from "../../utils/SpokePoolUtils.sol";
import { AddressToBytes32 } from "../../../../../contracts/libraries/AddressConverters.sol";

/**
 * @title SpokePool_ClaimRelayerRefundTest
 * @notice Tests for SpokePool relayer refund claiming with blacklisted addresses.
 * @dev Migrated from test/evm/hardhat/SpokePool.ClaimRelayerRefund.ts
 */
contract SpokePool_ClaimRelayerRefundTest is Test {
    using AddressToBytes32 for address;

    MockSpokePool public spokePool;
    ExpandedERC20WithBlacklist public destErc20;
    WETH9 public weth;

    address public deployerWallet;
    address public relayer;
    address public rando;

    uint256 public destinationChainId;

    function setUp() public {
        deployerWallet = makeAddr("deployer");
        relayer = makeAddr("relayer");
        rando = makeAddr("rando");

        // Deploy WETH
        weth = new WETH9();

        // Deploy destination ERC20 with blacklist functionality
        destErc20 = new ExpandedERC20WithBlacklist("L2 USD Coin", "L2 USDC", 18);
        // Add minter role (Roles.Minter = 1) to this test contract
        destErc20.addMember(1, address(this));

        // Deploy SpokePool
        vm.startPrank(deployerWallet);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, deployerWallet, deployerWallet))
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SpokePoolUtils.DESTINATION_CHAIN_ID);
        vm.stopPrank();

        destinationChainId = spokePool.chainId();

        // Seed the spoke pool with tokens
        destErc20.mint(address(spokePool), SpokePoolUtils.AMOUNT_HELD_BY_POOL);
    }

    /**
     * @notice Test that blacklisting an address prevents token transfers to that address.
     */
    function testBlacklistDestErc20() public {
        // Transfer tokens to relayer before blacklisting works
        destErc20.mint(deployerWallet, SpokePoolUtils.AMOUNT_TO_RELAY);

        vm.prank(deployerWallet);
        destErc20.transfer(relayer, SpokePoolUtils.AMOUNT_TO_RELAY);
        assertEq(destErc20.balanceOf(relayer), SpokePoolUtils.AMOUNT_TO_RELAY);

        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Attempt to transfer tokens to the blacklisted relayer should revert
        destErc20.mint(deployerWallet, SpokePoolUtils.AMOUNT_TO_RELAY);
        vm.prank(deployerWallet);
        vm.expectRevert("Recipient is blacklisted");
        destErc20.transfer(relayer, SpokePoolUtils.AMOUNT_TO_RELAY);
    }

    /**
     * @notice Test that distributing relayer refunds handles blacklisted addresses correctly.
     * Non-blacklisted addresses receive their refund, blacklisted ones get their refund deferred.
     */
    function testDistributeRelayerRefundsWithBlacklist() public {
        // Verify initial state
        assertEq(spokePool.getRelayerRefund(address(destErc20), relayer), 0);
        assertEq(destErc20.balanceOf(rando), 0);
        assertEq(destErc20.balanceOf(relayer), 0);

        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Distribute relayer refunds - some go to blacklisted address, some to non-blacklisted
        address[] memory refundAddresses = new address[](2);
        refundAddresses[0] = relayer;
        refundAddresses[1] = rando;

        uint256[] memory refundAmounts = new uint256[](2);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;
        refundAmounts[1] = SpokePoolUtils.AMOUNT_TO_RELAY;

        vm.prank(deployerWallet);
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // Blacklisted relayer's refund is deferred (stored as liability)
        assertEq(spokePool.getRelayerRefund(address(destErc20), relayer), SpokePoolUtils.AMOUNT_TO_RELAY);
        // Non-blacklisted rando receives their refund directly
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);
        // Blacklisted relayer doesn't receive tokens yet
        assertEq(destErc20.balanceOf(relayer), 0);
    }

    /**
     * @notice Test that a relayer with a failed repayment can claim their refund to an alternative recipient.
     */
    function testClaimRefundWithFailedRepayment() public {
        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Distribute relayer refund to blacklisted relayer
        address[] memory refundAddresses = new address[](1);
        refundAddresses[0] = relayer;

        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;

        vm.prank(deployerWallet);
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // Trying to claim to the blacklisted relayer address should fail
        vm.prank(relayer);
        vm.expectRevert("Recipient is blacklisted");
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), relayer.toBytes32());

        // Claim to an alternative (non-blacklisted) recipient should succeed
        assertEq(destErc20.balanceOf(rando), 0);

        vm.prank(relayer);
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), rando.toBytes32());

        // Rando should now have the relayer's refund
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);
    }

    /**
     * @notice Test that claiming with zero liability reverts.
     */
    function testClaimRelayerRefundNoLiability() public {
        // No liability exists for relayer, claim should revert
        vm.prank(relayer);
        vm.expectRevert();
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), relayer.toBytes32());
    }

    /**
     * @notice Test that only the original refund recipient can claim their deferred refund.
     */
    function testOnlyOriginalRecipientCanClaim() public {
        // Blacklist the relayer
        destErc20.setBlacklistStatus(relayer, true);

        // Distribute refund (will be deferred due to blacklist)
        address[] memory refundAddresses = new address[](1);
        refundAddresses[0] = relayer;

        uint256[] memory refundAmounts = new uint256[](1);
        refundAmounts[0] = SpokePoolUtils.AMOUNT_TO_RELAY;

        vm.prank(deployerWallet);
        spokePool.distributeRelayerRefunds(
            destinationChainId,
            SpokePoolUtils.AMOUNT_TO_RETURN,
            refundAmounts,
            0,
            address(destErc20),
            refundAddresses
        );

        // Rando (non-original recipient) trying to claim should fail
        vm.prank(rando);
        vm.expectRevert();
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), rando.toBytes32());

        // Original relayer can claim to alternative address
        vm.prank(relayer);
        spokePool.claimRelayerRefund(address(destErc20).toBytes32(), rando.toBytes32());
        assertEq(destErc20.balanceOf(rando), SpokePoolUtils.AMOUNT_TO_RELAY);
    }
}
