// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity ^0.8.0;

// import { Script } from "forge-std/Script.sol";
// import { console } from "forge-std/console.sol";
// import { PolygonTokenBridger } from "../../contracts/PolygonTokenBridger.sol";
// import { ChainUtils } from "../../script/utils/ChainUtils.sol";
// import { DeterministicDeployer } from "../../script/utils/DeterministicDeployer.sol";
// import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";
// import { PolygonRegistry } from "@maticnetwork/contracts/root/PolygonRegistry.sol";

// /**
//  * @title DeployPolygonTokenBridgerPolygon
//  * @notice Deploys the PolygonTokenBridger contract on Polygon (L2).
//  * @dev Migration of 010_deploy_polygon_token_bridger_polygon.ts script to Foundry.
//  *      Uses deterministic CREATE2 deployment with same salt (0x1234) as hardhat-deploy.
//  */
// contract DeployPolygonTokenBridgerPolygon is ChainUtils, DeterministicDeployer {
//     function run() external {
//         string memory deployerMnemonic = vm.envString("MNEMONIC");
//         uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
//         address deployer = vm.addr(deployerPrivateKey);
//         uint256 spokeChainId = block.chainid;

//         // Determine the hub chain ID based on spoke chain
//         uint256 hubChainId;
//         if (spokeChainId == POLYGON) {
//             hubChainId = MAINNET;
//         } else if (spokeChainId == POLYGON_AMOY) {
//             hubChainId = SEPOLIA;
//         } else {
//             revert("Unsupported spoke chain ID");
//         }

//         // Get the HubPool address from the L1 via environment variable or a file
//         address hubPoolAddress;
//         try vm.envAddress("L1_HUB_POOL_ADDRESS") returns (address addr) {
//             hubPoolAddress = addr;
//         } catch {
//             revert("L1_HUB_POOL_ADDRESS environment variable not set");
//         }

//         // Get addresses
//         address polygonRegistry = getL1Address(hubChainId, "polygonRegistry");
//         address weth = getWETH(hubChainId);
//         address wmatic = getWMATIC(spokeChainId);

//         console.log("Deploying PolygonTokenBridger on spoke chain %s for hub chain %s", spokeChainId, hubChainId);
//         console.log("Deployer: %s", deployer);
//         console.log("HubPool: %s", hubPoolAddress);
//         console.log("Polygon Registry: %s", polygonRegistry);
//         console.log("WETH: %s", weth);
//         console.log("WMATIC: %s", wmatic);

//         vm.startBroadcast(deployerPrivateKey);

//         // Ensure CREATE2 factory is deployed
//         ensureFactoryDeployed();

//         // Encode constructor arguments for PolygonTokenBridger
//         bytes memory constructorArgs = abi.encode(
//             hubPoolAddress,
//             PolygonRegistry(polygonRegistry),
//             WETH9Interface(weth),
//             wmatic,
//             hubChainId,
//             spokeChainId
//         );

//         // Get contract bytecode without constructor arguments
//         bytes memory bytecode = abi.encodePacked(type(PolygonTokenBridger).creationCode);

//         // Deploy deterministically using CREATE2 with the same salt as hardhat-deploy
//         address deployedAddress = deterministicDeploy(
//             "0x1234", // Same salt as in hardhat-deploy script
//             constructorArgs,
//             bytecode
//         );

//         console.log("PolygonTokenBridger deployed at: %s", deployedAddress);

//         vm.stopBroadcast();
//     }
// }
