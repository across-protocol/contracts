// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { BondToken } from "../../contracts/BondToken.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { ExtendedHubPoolInterface } from "../../contracts/BondToken.sol";

/**
 * @title DeployBondToken
 * @notice Deploys the BondToken contract.
 * @dev Migration of 019_deploy_bond_token.ts script to Foundry.
 */
contract DeployBondToken is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // The hub pool address should be provided as an environment variable
        address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");

        console.log("Deploying BondToken on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy BondToken
        BondToken bondToken = new BondToken(ExtendedHubPoolInterface(hubPoolAddress));
        console.log("BondToken deployed at: %s", address(bondToken));

        vm.stopBroadcast();
    }
}
