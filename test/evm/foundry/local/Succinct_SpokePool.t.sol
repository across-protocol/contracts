// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { Succinct_SpokePool } from "../../../../contracts/Succinct_SpokePool.sol";

contract SuccinctSpokePoolTest is Test {
    Succinct_SpokePool public spokePool;
    WETH9 public weth;

    address public owner;
    address public hubPool;
    address public succinctTargetAmb;
    address public rando;

    uint16 constant HUB_CHAIN_ID = 45;

    bytes32 public mockTreeRoot;

    function setUp() public {
        owner = makeAddr("owner");
        hubPool = makeAddr("hubPool");
        succinctTargetAmb = makeAddr("succinctTargetAmb");
        rando = makeAddr("rando");
        mockTreeRoot = keccak256("mockTreeRoot");

        // Fund accounts with ETH
        vm.deal(succinctTargetAmb, 1 ether);

        // Deploy WETH
        weth = new WETH9();

        // Deploy implementation
        Succinct_SpokePool implementation = new Succinct_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        // Deploy proxy
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(Succinct_SpokePool.initialize, (HUB_CHAIN_ID, succinctTargetAmb, 0, hubPool, hubPool))
            )
        );
        spokePool = Succinct_SpokePool(payable(proxy));
    }

    // Helper to call admin functions via the succinct AMB's handleTelepathy
    function _callAsAdmin(bytes memory data) internal {
        vm.prank(succinctTargetAmb);
        spokePool.handleTelepathy(HUB_CHAIN_ID, hubPool, data);
    }

    function testOnlyCrossDomainOwnerCanSetCrossDomainAdmin() public {
        bytes memory setCrossDomainAdminData = abi.encodeCall(spokePool.setCrossDomainAdmin, (rando));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert("Admin call not validated");
        spokePool.setCrossDomainAdmin(rando);

        // Wrong origin chain id
        vm.prank(succinctTargetAmb);
        vm.expectRevert("source chain not hub chain");
        spokePool.handleTelepathy(44, hubPool, setCrossDomainAdminData);

        // Wrong rootMessageSender address
        vm.prank(succinctTargetAmb);
        vm.expectRevert("sender not hubPool");
        spokePool.handleTelepathy(HUB_CHAIN_ID, rando, setCrossDomainAdminData);

        // Wrong calling address (not succinct AMB)
        vm.prank(rando);
        vm.expectRevert("caller not succinct AMB");
        spokePool.handleTelepathy(HUB_CHAIN_ID, hubPool, setCrossDomainAdminData);

        // Works with correct params
        _callAsAdmin(setCrossDomainAdminData);
        assertEq(spokePool.crossDomainAdmin(), rando);
    }

    function testCanUpgradeSuccinctTargetAmb() public {
        bytes memory setSuccinctTargetAmbData = abi.encodeCall(spokePool.setSuccinctTargetAmb, (rando));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert("Admin call not validated");
        spokePool.setSuccinctTargetAmb(rando);

        vm.prank(succinctTargetAmb);
        vm.expectRevert("Admin call not validated");
        spokePool.setSuccinctTargetAmb(rando);

        vm.prank(hubPool);
        vm.expectRevert("Admin call not validated");
        spokePool.setSuccinctTargetAmb(rando);

        // Works via handleTelepathy
        _callAsAdmin(setSuccinctTargetAmbData);
        assertEq(spokePool.succinctTargetAmb(), rando);
    }

    function testOnlyCrossDomainOwnerUpgradeLogicContract() public {
        // Deploy new implementation
        Succinct_SpokePool newImplementation = new Succinct_SpokePool(address(weth), 60 * 60, 9 * 60 * 60);

        bytes memory upgradeData = abi.encodeCall(spokePool.upgradeTo, (address(newImplementation)));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert("Admin call not validated");
        spokePool.upgradeTo(address(newImplementation));

        // Wrong origin chain id
        vm.prank(succinctTargetAmb);
        vm.expectRevert("source chain not hub chain");
        spokePool.handleTelepathy(44, hubPool, upgradeData);

        // Wrong sender
        vm.prank(succinctTargetAmb);
        vm.expectRevert("sender not hubPool");
        spokePool.handleTelepathy(HUB_CHAIN_ID, rando, upgradeData);

        // Works with correct params
        _callAsAdmin(upgradeData);
    }

    function testOnlyCrossDomainOwnerCanRelayRootBundle() public {
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert("Admin call not validated");
        spokePool.relayRootBundle(mockTreeRoot, mockTreeRoot);

        // Works with correct params
        _callAsAdmin(relayRootBundleData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockTreeRoot);
        assertEq(relayerRefundRoot, mockTreeRoot);
    }

    function testOnlyCrossDomainOwnerCanSetWithdrawalRecipient() public {
        bytes memory setWithdrawalRecipientData = abi.encodeCall(spokePool.setWithdrawalRecipient, (rando));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert("Admin call not validated");
        spokePool.setWithdrawalRecipient(rando);

        // Works with correct params
        _callAsAdmin(setWithdrawalRecipientData);
        assertEq(spokePool.withdrawalRecipient(), rando);
    }

    function testOnlyCrossDomainOwnerCanDeleteRelayerRefund() public {
        // First create a root bundle
        _callAsAdmin(abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot)));

        bytes memory emergencyDeleteData = abi.encodeCall(spokePool.emergencyDeleteRootBundle, (0));

        // Cannot call directly
        vm.prank(rando);
        vm.expectRevert("Admin call not validated");
        spokePool.emergencyDeleteRootBundle(0);

        // Works with correct params
        _callAsAdmin(emergencyDeleteData);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, bytes32(0));
        assertEq(relayerRefundRoot, bytes32(0));
    }

    function testCannotReenterHandleTelepathy() public {
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));
        bytes memory nestedData = abi.encodeCall(
            spokePool.handleTelepathy,
            (HUB_CHAIN_ID, hubPool, relayRootBundleData)
        );

        // Should revert when trying to re-enter handleTelepathy
        // The inner "adminCallValidated already set" error gets wrapped by "delegatecall failed"
        vm.prank(succinctTargetAmb);
        vm.expectRevert("delegatecall failed");
        spokePool.handleTelepathy(HUB_CHAIN_ID, hubPool, nestedData);
    }

    function testHandleTelepathyReturnsCorrectSelector() public {
        bytes memory relayRootBundleData = abi.encodeCall(spokePool.relayRootBundle, (mockTreeRoot, mockTreeRoot));

        vm.prank(succinctTargetAmb);
        bytes4 result = spokePool.handleTelepathy(HUB_CHAIN_ID, hubPool, relayRootBundleData);

        // Should return the handleTelepathy selector
        assertEq(result, spokePool.handleTelepathy.selector);
    }
}
