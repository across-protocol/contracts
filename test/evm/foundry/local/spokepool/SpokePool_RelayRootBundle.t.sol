// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";

contract SpokePoolRelayRootBundleTest is Test {
    MockSpokePool public spokePool;
    WETH9 public weth;
    address public owner;
    address public crossDomainAdmin;
    address public hubPool;

    bytes32 public mockRelayerRefundRoot;
    bytes32 public mockSlowRelayRoot;

    event RelayedRootBundle(
        uint32 indexed rootBundleId,
        bytes32 indexed relayerRefundRoot,
        bytes32 indexed slowRelayRoot
    );

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");

        mockRelayerRefundRoot = keccak256("mockRelayerRefundRoot");
        mockSlowRelayRoot = keccak256("mockSlowRelayRoot");

        weth = new WETH9();

        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth));
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, hubPool))
            )
        );
        spokePool = MockSpokePool(payable(proxy));
        vm.stopPrank();
    }

    function testRelayingRootStoresRootAndEmitsEvent() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit RelayedRootBundle(0, mockRelayerRefundRoot, mockSlowRelayRoot);
        spokePool.relayRootBundle(mockRelayerRefundRoot, mockSlowRelayRoot);

        (bytes32 slowRelayRoot, bytes32 relayerRefundRoot) = spokePool.rootBundles(0);
        assertEq(slowRelayRoot, mockSlowRelayRoot);
        assertEq(relayerRefundRoot, mockRelayerRefundRoot);

        vm.stopPrank();
    }
}
