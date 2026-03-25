// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { MockSpokePoolV2 } from "../../../../../contracts/test/MockSpokePoolV2.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";

contract SpokePoolUpgradesTest is Test {
    MockSpokePool public spokePool;
    WETH9 public weth;
    address public owner;
    address public crossDomainAdmin;
    address public hubPool;
    address public rando;

    event NewEvent(bool value);

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");
        rando = makeAddr("rando");

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

    function testCanUpgrade() public {
        // Deploy new V2 implementation
        MockSpokePoolV2 spokePoolV2Implementation = new MockSpokePoolV2(address(weth));

        address newHubPool = makeAddr("newHubPool");
        bytes memory reinitializeData = abi.encodeCall(MockSpokePoolV2.reinitialize, (newHubPool));

        // Only owner can upgrade
        vm.prank(rando);
        vm.expectRevert("Ownable: caller is not the owner");
        spokePool.upgradeToAndCall(address(spokePoolV2Implementation), reinitializeData);

        // Owner can upgrade
        vm.prank(owner);
        spokePool.upgradeToAndCall(address(spokePoolV2Implementation), reinitializeData);

        // Hub pool (withdrawal recipient) should be changed
        MockSpokePoolV2 upgradedSpokePool = MockSpokePoolV2(payable(address(spokePool)));
        assertEq(upgradedSpokePool.withdrawalRecipient(), newHubPool);

        // Can't reinitialize again
        vm.expectRevert("Initializable: contract is already initialized");
        upgradedSpokePool.reinitialize(newHubPool);

        // Can call new function
        vm.expectEmit(true, true, true, true);
        emit NewEvent(true);
        upgradedSpokePool.emitEvent();
    }
}
