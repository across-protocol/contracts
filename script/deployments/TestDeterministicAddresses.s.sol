// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DeterministicDeployer } from "../utils/DeterministicDeployer.sol";
import { PolygonTokenBridger } from "../../contracts/PolygonTokenBridger.sol";
import { SpokePoolVerifier } from "../../contracts/SpokePoolVerifier.sol";
import { MulticallHandler } from "../../contracts/handlers/MulticallHandler.sol";
import { ChainUtils } from "../utils/ChainUtils.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";

/**
 * @title TestDeterministicAddresses
 * @notice Tests that our CREATE2 implementation produces the same addresses as hardhat-deploy
 * @dev Run this script to check the predicted addresses for deterministic deployments
 */
contract TestDeterministicAddresses is DeterministicDeployer, ChainUtils {
    function run() external {
        // This is a simulation script, so no broadcast needed
        console.log("\n=== Testing Deterministic Deployment Addresses ===\n");

        // Compare addresses for SpokePoolVerifier (no constructor args)
        bytes memory spokePoolVerifierBytecode = abi.encodePacked(type(SpokePoolVerifier).creationCode);
        bytes memory spokePoolVerifierArgs = new bytes(0);
        bytes32 salt1234 = 0x1234000000000000000000000000000000000000000000000000000000000000;
        address spokePoolVerifierAddress = getCreate2Address(
            salt1234,
            abi.encodePacked(spokePoolVerifierBytecode, spokePoolVerifierArgs)
        );
        console.log("SpokePoolVerifier address (salt: 0x1234):");
        console.log(spokePoolVerifierAddress);
        console.log("");

        // Compare addresses for MulticallHandler (no constructor args)
        bytes memory multicallHandlerBytecode = abi.encodePacked(type(MulticallHandler).creationCode);
        bytes memory multicallHandlerArgs = new bytes(0);
        bytes32 salt12345678 = 0x1234567800000000000000000000000000000000000000000000000000000000;
        address multicallHandlerAddress = getCreate2Address(
            salt12345678,
            abi.encodePacked(multicallHandlerBytecode, multicallHandlerArgs)
        );
        console.log("MulticallHandler address (salt: 0x12345678):");
        console.log(multicallHandlerAddress);
        console.log("");

        // Polygon bridger on Ethereum (L1)
        uint256 hubChainId = MAINNET;
        uint256 spokeChainId = POLYGON;
        address hubPoolAddress = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5; // Example HubPool address
        address polygonRegistry = getL1Address(hubChainId, "polygonRegistry");
        address l1Weth = getWETH(hubChainId);
        address l2WrappedMatic = getWMATIC(spokeChainId);

        bytes memory polygonTokenBridgerBytecode = abi.encodePacked(type(PolygonTokenBridger).creationCode);
        bytes memory polygonTokenBridgerArgs = abi.encode(
            hubPoolAddress,
            polygonRegistry,
            WETH9Interface(l1Weth),
            l2WrappedMatic,
            hubChainId,
            spokeChainId
        );

        address polygonTokenBridgerL1Address = getCreate2Address(
            salt1234,
            abi.encodePacked(polygonTokenBridgerBytecode, polygonTokenBridgerArgs)
        );

        console.log("PolygonTokenBridger L1 address (salt: 0x1234):");
        console.log(polygonTokenBridgerL1Address);
        console.log("");

        // Polygon bridger on Polygon (L2) - should be the same address!
        // Swap the hub and spoke chain IDs for L2 deployment
        bytes memory polygonTokenBridgerL2Args = abi.encode(
            hubPoolAddress,
            polygonRegistry,
            WETH9Interface(l1Weth),
            l2WrappedMatic,
            hubChainId, // Still using the L1 chain ID
            spokeChainId // Still using the L2 chain ID
        );

        address polygonTokenBridgerL2Address = getCreate2Address(
            salt1234,
            abi.encodePacked(polygonTokenBridgerBytecode, polygonTokenBridgerL2Args)
        );

        console.log("PolygonTokenBridger L2 address (salt: 0x1234):");
        console.log(polygonTokenBridgerL2Address);

        // The addresses should be different because the constructor arguments differ
        // This is expected and by design - the bridger on L1 and L2 have different constructor parameters
        console.log(
            "\nAre PolygonTokenBridger addresses the same? ",
            polygonTokenBridgerL1Address == polygonTokenBridgerL2Address ? "Yes" : "No"
        );

        // To get the same address on both chains, we would need identical constructor args
        // Typically this means the order of hubChainId and spokeChainId would need to be flipped on L2
        console.log("\n=== Testing Finished ===\n");
    }
}
