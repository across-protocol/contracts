// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { SpokePoolVerifier } from "../../contracts/SpokePoolVerifier.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { DeterministicDeployer } from "../../script/utils/DeterministicDeployer.sol";

/**
 * @title DeploySpokePoolVerifier
 * @notice Deploys the SpokePoolVerifier contract.
 * @dev Migration of 023_deploy_spoke_pool_verifier.ts script to Foundry.
 *      Uses deterministic CREATE2 deployment with same salt (0x1234) as hardhat-deploy.
 */
contract DeploySpokePoolVerifier is ChainUtils, DeterministicDeployer {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        console.log("Deploying SpokePoolVerifier on chain %s", chainId);
        console.log("Deployer: %s", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Ensure CREATE2 factory is deployed
        ensureFactoryDeployed();

        // SpokePoolVerifier has no constructor arguments
        bytes memory constructorArgs = new bytes(0);

        // Get contract bytecode
        bytes memory bytecode = abi.encodePacked(type(SpokePoolVerifier).creationCode);

        // Deploy deterministically using CREATE2 with the same salt as hardhat-deploy
        address deployedAddress = deterministicDeploy(
            "0x1234", // Same salt as in hardhat-deploy script
            constructorArgs,
            bytecode
        );

        console.log("SpokePoolVerifier deployed deterministically at: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
