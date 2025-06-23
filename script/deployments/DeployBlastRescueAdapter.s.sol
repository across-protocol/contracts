// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { Blast_RescueAdapter } from "../../contracts/chain-adapters/Blast_RescueAdapter.sol";
import { USDYieldManager } from "../../contracts/Blast_DaiRetriever.sol";

/**
 * @title DeployBlastRescueAdapter
 * @notice Deploys the Blast_RescueAdapter contract on Ethereum mainnet.
 * @dev This adapter is built to retrieve Blast USDB from the USDBYieldManager contract on Ethereum
 * that was sent to the HubPool as the `recipient`. These funds should ideally be sent to the
 * BlastRetriever address on Ethereum. This contract can be used to retrieve these funds.
 */
contract DeployBlastRescueAdapter is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // This should only be deployed on Ethereum mainnet (or test networks)
        require(chainId == MAINNET || chainId == SEPOLIA, "Must deploy on Ethereum mainnet or Sepolia");

        // Get required addresses
        address blastDaiRetrieverAddress = vm.envOr("BLAST_DAI_RETRIEVER", getL1Address(chainId, "blastDaiRetriever"));
        address usdYieldManagerAddress = getL1Address(chainId, "blastYieldManager");

        console.log("Deploying Blast_RescueAdapter on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Blast DAI Retriever: %s", blastDaiRetrieverAddress);
        console.log("USD Yield Manager: %s", usdYieldManagerAddress);

        vm.startBroadcast(deployerPrivateKey);

        Blast_RescueAdapter adapter = new Blast_RescueAdapter(
            blastDaiRetrieverAddress,
            USDYieldManager(usdYieldManagerAddress)
        );
        console.log("Blast_RescueAdapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }
}
