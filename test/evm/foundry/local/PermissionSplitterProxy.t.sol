// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HubPool } from "../../../../contracts/HubPool.sol";
import { PermissionSplitterProxy } from "../../../../contracts/PermissionSplitterProxy.sol";
import { HubPoolTestBase, HubPoolFixtureData } from "../utils/HubPoolTestBase.sol";

/**
 * @title PermissionSplitterProxyTest
 * @notice Tests for PermissionSplitterProxy (migrated from PermissionSplitterProxy.ts)
 */
contract PermissionSplitterProxyTest is HubPoolTestBase {
    HubPool hubPool;
    HubPool hubPoolProxy;
    PermissionSplitterProxy permissionSplitter;

    address owner;
    address delegate;

    bytes32 delegateRole;
    bytes32 defaultAdminRole;

    // enableL1TokenForLiquidityProvision(address) selector
    bytes4 constant ENABLE_TOKEN_SELECTOR = 0xb60c2d7d;

    function setUp() public {
        // Create fixture (deploys HubPool, WETH, etc.)
        HubPoolFixtureData memory data = createHubPoolFixture();
        hubPool = data.hubPool;

        // Setup accounts
        owner = address(this); // Test contract is the owner since it deployed HubPool
        delegate = makeAddr("delegate");

        // Deploy PermissionSplitterProxy
        permissionSplitter = new PermissionSplitterProxy(address(hubPool));

        // Create hubPoolProxy by casting permissionSplitter to HubPool interface
        hubPoolProxy = HubPool(payable(address(permissionSplitter)));

        // Setup roles
        delegateRole = keccak256("DELEGATE_ROLE");
        defaultAdminRole = bytes32(0);

        // Grant delegate role to delegate address
        permissionSplitter.grantRole(delegateRole, delegate);

        // Transfer HubPool ownership to permissionSplitter
        hubPool.transferOwnership(address(permissionSplitter));
    }

    function test_CannotRunMethodUntilWhitelisted() public {
        // Delegate cannot call enableL1TokenForLiquidityProvision until whitelisted
        vm.prank(delegate);
        vm.expectRevert("Not allowed to call");
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Whitelist the selector for delegate role
        permissionSplitter.__setRoleForSelector(ENABLE_TOKEN_SELECTOR, delegateRole);

        // Now delegate can call
        vm.prank(delegate);
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Verify the token is enabled (PooledToken struct: lpToken, isEnabled, lastLpFeeUpdate, utilizedReserves, liquidReserves, undistributedLpFees)
        (, bool isEnabled, , , , ) = hubPool.pooledTokens(address(fixture.weth));
        assertTrue(isEnabled);
    }

    function test_OwnerCanRunWithoutWhitelisting() public {
        // Owner can call any function without whitelisting
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Verify the token is enabled
        (, bool isEnabled, , , , ) = hubPool.pooledTokens(address(fixture.weth));
        assertTrue(isEnabled);
    }

    function test_OwnerCanRevokeRole() public {
        // Delegate cannot call without whitelist
        vm.prank(delegate);
        vm.expectRevert("Not allowed to call");
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Whitelist the selector for delegate role
        permissionSplitter.__setRoleForSelector(ENABLE_TOKEN_SELECTOR, delegateRole);

        // Delegate can now call
        vm.prank(delegate);
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Verify the token is enabled
        (, bool isEnabled, , , , ) = hubPool.pooledTokens(address(fixture.weth));
        assertTrue(isEnabled);

        // Owner revokes the delegate role from delegate
        permissionSplitter.revokeRole(delegateRole, delegate);

        // Delegate can no longer call (try with USDC)
        vm.prank(delegate);
        vm.expectRevert("Not allowed to call");
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.usdc));
    }

    function test_OwnerCanRevokeSelector() public {
        // Delegate cannot call without whitelist
        vm.prank(delegate);
        vm.expectRevert("Not allowed to call");
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Whitelist the selector for delegate role
        permissionSplitter.__setRoleForSelector(ENABLE_TOKEN_SELECTOR, delegateRole);

        // Delegate can now call
        vm.prank(delegate);
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Verify the token is enabled
        (, bool isEnabled, , , , ) = hubPool.pooledTokens(address(fixture.weth));
        assertTrue(isEnabled);

        // Owner revokes the selector by setting it back to DEFAULT_ADMIN_ROLE
        permissionSplitter.__setRoleForSelector(ENABLE_TOKEN_SELECTOR, defaultAdminRole);

        // Delegate can no longer call (try with USDC)
        vm.prank(delegate);
        vm.expectRevert("Not allowed to call");
        hubPoolProxy.enableL1TokenForLiquidityProvision(address(fixture.usdc));
    }
}
