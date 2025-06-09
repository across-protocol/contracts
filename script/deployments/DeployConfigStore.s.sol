// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AcrossConfigStore } from "../../contracts/AcrossConfigStore.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";

/**
 * @title DeployConfigStore
 * @notice Deploys the AcrossConfigStore contract.
 * @dev Migration of 014_deploy_config_store.ts script to Foundry.
 */
contract DeployConfigStore is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        console.log("Deploying AcrossConfigStore on chain %s", chainId);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AcrossConfigStore - no constructor arguments
        AcrossConfigStore configStore = new AcrossConfigStore();
        console.log("AcrossConfigStore deployed at: %s", address(configStore));

        vm.stopBroadcast();
    }
}
