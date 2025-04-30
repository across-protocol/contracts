// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @title MockDeploy
 * @notice A simple Foundry script to test the deployment pipeline
 */
contract MockDeploy is Script {
    function run() external {
        string memory deployerMnemonic = "test test test test test test test test test test test junk";
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Just a mock deployment to validate the pipeline
        MockContract mock = new MockContract();
        console.log("Mock contract deployed at:", address(mock));

        vm.stopBroadcast();
    }
}

contract MockContract {
    uint256 public value;

    constructor() {
        value = 42;
    }
}
