// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Create2Factory } from "../../../../contracts/Create2Factory.sol";

contract InitializedContract {
    bool public initialized;

    function initialize(bool _initialized) external {
        initialized = _initialized;
    }
}

contract Create2FactoryTest is Test {
    Create2Factory create2Factory;

    function setUp() public {
        create2Factory = new Create2Factory();
    }

    function testDeterministicDeployNoValue() public {
        bytes32 salt = "12345";
        bytes memory creationCode = abi.encodePacked(type(InitializedContract).creationCode);

        address computedAddress = Create2.computeAddress(salt, keccak256(creationCode), address(create2Factory));
        bytes memory initializationData = abi.encodeWithSelector(InitializedContract.initialize.selector, true);
        address deployedAddress = create2Factory.deploy(0, salt, creationCode, initializationData);

        assertEq(computedAddress, deployedAddress);
        assertTrue(InitializedContract(deployedAddress).initialized());
    }
}
