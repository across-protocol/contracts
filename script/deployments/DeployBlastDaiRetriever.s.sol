// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { Blast_DaiRetriever, USDYieldManager } from "../../contracts/Blast_DaiRetriever.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
 * @title DeployBlastDaiRetriever
 * @notice Deploys the Blast_DaiRetriever contract on Ethereum mainnet
 * to facilitate DAI transfers from Blast to the HubPool.
 */
contract DeployBlastDaiRetriever is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // This should only be deployed on Ethereum mainnet (or test networks)
        require(chainId == MAINNET || chainId == SEPOLIA, "Must deploy on Ethereum mainnet or Sepolia");

        // Get required addresses
        address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");
        address daiAddress = getL1Address(chainId, "dai");
        address usdYieldManagerAddress = getL1Address(chainId, "blastYieldManager");

        console.log("Deploying Blast_DaiRetriever on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("DAI: %s", daiAddress);
        console.log("USD Yield Manager: %s", usdYieldManagerAddress);

        vm.startBroadcast(deployerPrivateKey);

        Blast_DaiRetriever daiRetriever = new Blast_DaiRetriever(
            hubPoolAddress,
            USDYieldManager(usdYieldManagerAddress),
            IERC20Upgradeable(daiAddress)
        );
        console.log("Blast_DaiRetriever deployed at: %s", address(daiRetriever));

        vm.stopBroadcast();
    }
}
