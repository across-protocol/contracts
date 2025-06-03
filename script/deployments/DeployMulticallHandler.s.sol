// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { DeterministicDeployer } from "../../script/utils/DeterministicDeployer.sol";
import { MulticallHandler } from "../../contracts/handlers/MulticallHandler.sol";

/**
 * @title DeployMulticallHandler
 * @notice Deploys the MulticallHandler contract using deterministic deployment.
 * @dev Uses deterministic CREATE2 deployment with salt "0x12345678" as used in hardhat-deploy.
 *      This ensures the contract is deployed at the same address on all EVM-compatible chains.
 */
contract DeployMulticallHandler is ChainUtils, DeterministicDeployer {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        console.log("Deploying MulticallHandler on chain %s", chainId);
        console.log("Deployer: %s", deployer);

        // Special note for ZkSync and Linea which are not fully EVM-equivalent
        if (chainId == ZK_SYNC || chainId == LINEA) {
            console.log("Warning: This chain may not be fully EVM-equivalent.");
            console.log("The created address might differ from other chains despite using CREATE2.");
        }

        vm.startBroadcast(deployerPrivateKey);

        // Ensure CREATE2 factory is deployed
        ensureFactoryDeployed();

        // MulticallHandler has no constructor arguments
        bytes memory constructorArgs = new bytes(0);

        // Get contract bytecode
        bytes memory bytecode = abi.encodePacked(type(MulticallHandler).creationCode);

        // Deploy deterministically using CREATE2 with the same salt as hardhat-deploy
        address deployedAddress = deterministicDeploy(
            "0x12345678", // Same salt as in hardhat-deploy script
            constructorArgs,
            bytecode
        );

        console.log("MulticallHandler deployed deterministically at: %s", deployedAddress);

        vm.stopBroadcast();
    }
}
