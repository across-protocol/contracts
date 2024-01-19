// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import "forge-std/console.sol";

import { HubPool } from "../../contracts/HubPool.sol";
import { SpokePool } from "../../contracts/SpokePool.sol";
import { LpTokenFactory } from "../../contracts/LpTokenFactory.sol";
import { PermissionSplitterProxy } from "../../contracts/PermissionSplitterProxy.sol";

// Run this test to verify PermissionSplitter behavior when changing ownership of the HubPool
// to it. Therefore this test should be run as a fork test via:
// - forge test --fork-url <MAINNET-RPC-URL>
contract PermissionSplitterTest is Test {
    HubPool hubPool;
    HubPool hubPoolProxy;
    SpokePool ethereumSpokePool;
    PermissionSplitterProxy permissionSplitter;

    // defaultAdmin is the deployer of the PermissionSplitter and has authority
    // to call any function on the HubPool. Therefore this should be a highly secure
    // contract account such as a MultiSig contract.
    address defaultAdmin;
    // Pause admin should only be allowed to pause the HubPool.
    address pauseAdmin;

    bytes32 constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes4 constant PAUSE_SELECTOR = bytes4(keccak256("setPaused(bool)"));
    // Error emitted when non-owner calls onlyOwner HubPool function.
    bytes constant OWNABLE_NOT_OWNER_ERROR = bytes("Ownable: caller is not the owner");
    // Error emitted when calling PermissionSplitterProxy function with incorrect role.
    bytes constant PROXY_NOT_ALLOWED_TO_CALL_ERROR = bytes("Not allowed to call");

    function setUp() public {
        // Since this test file is designed to run against a mainnet fork, hardcode the following system
        // contracts to skip the setup we'd usually need to run to use brand new contracts.
        hubPool = HubPool(payable(0xc186fA914353c44b2E33eBE05f21846F1048bEda));
        ethereumSpokePool = SpokePool(payable(0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5));

        // For the purposes of this test, the default admin will be the current owner of the
        // HubPool, which we can assume is a highly secured account.
        defaultAdmin = hubPool.owner();
        pauseAdmin = vm.addr(1);

        // Deploy PermissionSplitter from default admin account and then
        // create and assign roles.
        vm.startPrank(defaultAdmin);
        // Default admin can call any ownable function, which no one else can call without
        // the correct role.
        permissionSplitter = new PermissionSplitterProxy(address(hubPool));
        permissionSplitter.grantRole(PAUSE_ROLE, pauseAdmin);
        // Grant anyone with the pause role the ability to call setPaused
        permissionSplitter.__setRoleForSelector(PAUSE_SELECTOR, PAUSE_ROLE);
        vm.stopPrank();

        vm.prank(defaultAdmin);
        hubPool.transferOwnership(address(permissionSplitter));
        hubPoolProxy = HubPool(payable(permissionSplitter));
    }

    function testPause() public {
        // Calling HubPool setPaused directly should fail, even if called by previous owner.
        vm.startPrank(defaultAdmin);
        vm.expectRevert(OWNABLE_NOT_OWNER_ERROR);
        hubPool.setPaused(true);
        vm.stopPrank();

        // Must call HubPool via PermissionSplitterProxy.
        vm.prank(pauseAdmin);
        hubPoolProxy.setPaused(true);
        assertTrue(hubPool.paused());
    }

    function testCallSpokePoolFunction() public {
        bytes32 fakeRoot = keccak256("new admin root");
        bytes memory spokeFunctionCallData = abi.encodeWithSignature(
            "relayRootBundle(bytes32,bytes32)",
            fakeRoot,
            fakeRoot
        );
        uint256 spokeChainId = 1;

        vm.expectRevert(PROXY_NOT_ALLOWED_TO_CALL_ERROR);
        hubPoolProxy.relaySpokePoolAdminFunction(spokeChainId, spokeFunctionCallData);
        vm.expectRevert(OWNABLE_NOT_OWNER_ERROR);
        hubPool.relaySpokePoolAdminFunction(spokeChainId, spokeFunctionCallData);

        vm.startPrank(defaultAdmin);
        vm.expectCall(address(ethereumSpokePool), spokeFunctionCallData);
        hubPoolProxy.relaySpokePoolAdminFunction(spokeChainId, spokeFunctionCallData);
        vm.stopPrank();
    }

    function testFallback() public {
        // Calling a function that doesn't exist on target or PermissionSplitter calls the HubPool's
        // fallback function which wraps any msg.value into wrapped native token.
        uint256 balBefore = address(hubPool).balance;

        // Calling fake function as admin with no value succeeds and does nothing.
        vm.prank(defaultAdmin);
        (bool success1, ) = address(hubPoolProxy).call("doesNotExist()");
        assertTrue(success1);

        // Calling fake function as admin with value also succeeds and wraps the msg.value
        // and then does nothing.
        vm.deal(defaultAdmin, 1 ether);
        vm.prank(defaultAdmin);
        (bool success2, bytes memory reason) = address(hubPoolProxy).call{ value: 1 ether }("doesNotExist()");
        assertTrue(success2);
        assertEq(address(hubPool).balance, balBefore);
    }

    function testFunctionSelectorCollisions() public {
        // TODO: Test that HubPool has no public function selector collisions with itself.
        // TODO: Test that PermissionSplitter has no function selector collisions with HubPool.
    }
}
