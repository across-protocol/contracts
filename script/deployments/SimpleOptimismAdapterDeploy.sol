// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Optimism_Adapter } from "../../contracts/chain-adapters/Optimism_Adapter.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title SimpleOptimismAdapterDeploy
 * @notice A simplified deployment script for the Optimism adapter
 */
contract SimpleOptimismAdapterDeploy is Script {
    function run() external {
        string memory deployerMnemonic = "test test test test test test test test test test test junk";
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);

        // Mock addresses for testing
        address mockWeth = address(0xdD2FD4581271e230360230F9337D5c0430Bf44C0);
        address mockL1CrossDomainMessenger = address(0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199);
        address mockL1StandardBridge = address(0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6);
        address mockUsdc = address(0x610178dA211FEF7D417bC0e6FeD39F05609AD788);
        address mockCctpTokenMessenger = address(0x9A676e781A523b5d0C0e43731313A708CB607508);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Optimism_Adapter
        Optimism_Adapter adapter = new Optimism_Adapter(
            WETH9Interface(mockWeth),
            mockL1CrossDomainMessenger,
            IL1StandardBridge(mockL1StandardBridge),
            IERC20(mockUsdc),
            ITokenMessenger(mockCctpTokenMessenger)
        );
        console.log("Optimism_Adapter deployed at:", address(adapter));

        vm.stopBroadcast();
    }
}
