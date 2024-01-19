// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import "forge-std/console.sol";

import { Finder } from "@uma/core/contracts/data-verification-mechanism/implementation/Finder.sol";
import { HubPool } from "../../contracts/HubPool.sol";
import { LpTokenFactory } from "../../contracts/LpTokenFactory.sol";
import { PermissionSplitterProxy } from "../../contracts/PermissionSplitterProxy.sol";

// Run this test to verify PermissionSplitter behavior when changing ownership of the HubPool
// to it. Therefore this test should be run as a fork test via:
// - forge test --fork-url <MAINNET-RPC-URL>
contract PermissionSplitterTest is Test {
    HubPool hubPool;
    PermissionSplitterProxy permissionSplitter;

    // defaultAdmin is the deployer of the PermissionSplitter and has authority
    // to call any function on the HubPool. Therefore this should be a highly secure
    // contract account such as a MultiSig contract.
    address defaultAdmin;
    // Pause admin should only be allowed to pause the HubPool.
    address pauseAdmin;

    bytes32 constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes4 constant PAUSE_SELECTOR = bytes4(keccak256("setPaused(bool)"));

    function setUp() public {
        hubPool = HubPool(payable(0xc186fA914353c44b2E33eBE05f21846F1048bEda));

        // For the purposes of this test, the default admin will be the current owner of the
        // HubPool, which we can assume is a highly secured account.
        defaultAdmin = hubPool.owner();
        pauseAdmin = vm.addr(1);
        permissionSplitter.grantRole(PAUSE_ROLE, pauseAdmin);

        // Deploy PermissionSplitter from default admin account.
        vm.prank(defaultAdmin);
        permissionSplitter = new PermissionSplitterProxy(address(hubPool));

        hubPool.transferOwnership(address(permissionSplitter));
    }

    function testMain() public {
        // Grant anyone with the pause role the ability to call setPaused
        vm.prank(defaultAdmin);
        permissionSplitter.__setRoleForSelector(PAUSE_SELECTOR, PAUSE_ROLE);
        vm.prank(pauseAdmin);
        hubPool.setPaused(true);
    }
}
