// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Ethereum_Adapter } from "../../contracts/chain-adapters/Ethereum_Adapter.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";

/**
 * @title DeployEthereumAdapter
 * @notice Deploys the Ethereum adapter contract.
 * @dev Migration of 006_deploy_ethereum_adapter.ts script to Foundry.
 */
contract DeployEthereumAdapter is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        console.log("Deploying Ethereum Adapter on chain %s", chainId);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Ethereum_Adapter - no constructor arguments
        Ethereum_Adapter adapter = new Ethereum_Adapter();
        console.log("Ethereum_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }
}
