// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Optimism_SpokePool } from "../../contracts/Optimism_SpokePool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title SimpleOptimismSpokePoolDeploy
 * @notice A simplified deployment script for the Optimism spoke pool
 */
contract SimpleOptimismSpokePoolDeploy is Script {
    function run() external {
        string memory deployerMnemonic = "test test test test test test test test test test test junk";
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);

        // Mock addresses for testing
        address mockWrappedNative = address(0x4200000000000000000000000000000000000006); // WETH on Optimism
        address mockUsdc = address(0x7F5c764cBc14f9669B88837ca1490cCa17c31607); // USDC on Optimism
        address mockCctpTokenMessenger = address(0x2B4069517957735bE00ceE0fadAE88a26365528f); // CCTP on Optimism

        // Parameters for initialization
        uint32 depositQuoteTimeBuffer = 3600; // 1 hour
        uint32 fillDeadlineBuffer = 21600; // 6 hours

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Optimism_SpokePool
        Optimism_SpokePool spokePool = new Optimism_SpokePool(
            mockWrappedNative,
            depositQuoteTimeBuffer,
            fillDeadlineBuffer,
            IERC20(mockUsdc),
            ITokenMessenger(mockCctpTokenMessenger)
        );
        console.log("Optimism_SpokePool deployed at:", address(spokePool));

        // We would call initialize here to set up the contract properly, but that's a separate step
        // spokePool.initialize(0, hubPool, etc...)

        vm.stopBroadcast();
    }
}
