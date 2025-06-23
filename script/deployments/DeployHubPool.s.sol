// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { LpTokenFactory } from "../../contracts/LpTokenFactory.sol";
import { HubPool } from "../../contracts/HubPool.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";

/**
 * @title DeployHubPool
 * @notice Deploys the HubPool contract and its dependencies.
 * @dev This is a migration of the original 001_deploy_hubpool.ts script to Foundry.
 */
contract DeployHubPool is Script, Test, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Load addresses based on current chain ID
        address finder = getL1Address(chainId, "finder");
        address weth = getWETH(chainId);
        address zeroAddress = address(0);

        console.log("Deploying LpTokenFactory and HubPool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Using finder at: %s", finder);
        console.log("Using WETH at: %s", weth);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy LpTokenFactory first
        LpTokenFactory lpTokenFactory = new LpTokenFactory();
        console.log("LpTokenFactory deployed at: %s", address(lpTokenFactory));

        // Deploy HubPool
        // We need to cast the addresses to the appropriate interfaces
        HubPool hubPool = new HubPool(
            LpTokenFactory(address(lpTokenFactory)),
            FinderInterface(finder),
            WETH9Interface(weth),
            zeroAddress
        );
        console.log("HubPool deployed at: %s", address(hubPool));

        vm.stopBroadcast();
    }
}
