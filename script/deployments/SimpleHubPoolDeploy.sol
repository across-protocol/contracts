// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { LpTokenFactory } from "../../contracts/LpTokenFactory.sol";
import { HubPool } from "../../contracts/HubPool.sol";
import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";

/**
 * @title SimpleHubPoolDeploy
 * @notice A simplified deployment script for the HubPool and its dependencies
 */
contract SimpleHubPoolDeploy is Script {
    function run() external {
        string memory deployerMnemonic = "test test test test test test test test test test test junk";
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);

        // Mock addresses for testing
        address mockFinder = address(0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199);
        address mockWeth = address(0xdD2FD4581271e230360230F9337D5c0430Bf44C0);
        address zeroAddress = address(0);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy LpTokenFactory
        LpTokenFactory lpTokenFactory = new LpTokenFactory();
        console.log("LpTokenFactory deployed at:", address(lpTokenFactory));

        // Deploy HubPool with the mock addresses
        HubPool hubPool = new HubPool(
            LpTokenFactory(address(lpTokenFactory)),
            FinderInterface(mockFinder),
            WETH9Interface(mockWeth),
            zeroAddress
        );
        console.log("HubPool deployed at:", address(hubPool));

        vm.stopBroadcast();
    }
}
