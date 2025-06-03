// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../utils/ChainUtils.sol";
import { AcrossOriginSettler } from "../../contracts/erc7683/AcrossOriginSettler.sol";
import { SpokePool } from "../../contracts/SpokePool.sol";
import { IPermit2 } from "../../contracts/external/interfaces/IPermit2.sol";

/**
 * @title DeployAcrossOriginSettler
 * @notice Deploy script for the AcrossOriginSettler contract
 * @dev This contract deploys AcrossOriginSettler and sets up destination settlers for all supported chains
 */
contract DeployAcrossOriginSettler is Script, ChainUtils {
    // Standard Permit2 address on most chains
    address constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Time parameter for calculating quote timestamp
    uint256 constant QUOTE_BEFORE_DEADLINE = 1800; // 30 minutes in seconds

    // JSON file containing deployments
    string constant DEPLOYMENTS_FILE = "./deployments/deployments.json";

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get current chain's SpokePool address
        address spokePoolAddress = getSpokePoolFromDeployments(chainId);

        // If no SpokePool deployment found, use a dummy address for testing
        if (spokePoolAddress == address(0)) {
            console.log("No SpokePool deployment found for chain %s, using dummy address for testing", chainId);
            spokePoolAddress = address(0x1234567890123456789012345678901234567890);
        }

        console.log("Deploying AcrossOriginSettler on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("SpokePool: %s", spokePoolAddress);
        console.log("Permit2: %s", PERMIT2_ADDRESS);
        console.log("Quote Before Deadline: %s", QUOTE_BEFORE_DEADLINE);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy AcrossOriginSettler
        AcrossOriginSettler originSettler = new AcrossOriginSettler(
            SpokePool(payable(spokePoolAddress)),
            IPermit2(PERMIT2_ADDRESS),
            QUOTE_BEFORE_DEADLINE
        );
        console.log("AcrossOriginSettler deployed at: %s", address(originSettler));

        // Set up destination settlers for supported chains
        // Each supported chain will have its SpokePool registered as a destination settler
        setDestinationSettlers(originSettler);

        // Renounce ownership after setting up all destination settlers
        // This means no further changes can be made to the destination settlers
        console.log("Renouncing ownership of AcrossOriginSettler contract");
        originSettler.renounceOwnership();
        console.log("Ownership renounced");

        // Log deployment information for manual addition to deployments.json
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Chain ID: %s", chainId);
        console.log("AcrossOriginSettler deployed at: %s", address(originSettler));
        console.log("Block number: %s", block.number);
        console.log("");
        console.log("Please add this entry to deployments.json:");
        console.log("{");
        console.log('  "%s": {', chainId);
        console.log('    "AcrossOriginSettler": {');
        console.log('      "address": "%s",', address(originSettler));
        console.log('      "blockNumber": %s', block.number);
        console.log("    }");
        console.log("  }");
        console.log("}");
        console.log("=========================");

        vm.stopBroadcast();
    }

    /**
     * @notice Set destination settlers for all supported chains
     * @param originSettler The deployed AcrossOriginSettler contract
     */
    function setDestinationSettlers(AcrossOriginSettler originSettler) internal {
        // Array of supported chain IDs to set destinations for
        uint256[] memory supportedChains = getSupportedChains();

        for (uint256 i = 0; i < supportedChains.length; i++) {
            uint256 destChainId = supportedChains[i];

            // Skip current chain as we don't need to set it as a destination
            if (destChainId == block.chainid) continue;

            // Get the SpokePool address from deployments.json
            address spokePoolAddress = getSpokePoolFromDeployments(destChainId);

            // Skip chains with no deployment
            if (spokePoolAddress == address(0)) {
                console.log("No SpokePool found for chain %s, skipping", destChainId);
                continue;
            }

            console.log("Setting destination settler for chain %s: %s", destChainId, spokePoolAddress);
            originSettler.setDestinationSettler(destChainId, spokePoolAddress);
        }
    }

    /**
     * @notice Returns list of supported chain IDs
     * @return Array of supported chain IDs
     */
    function getSupportedChains() internal pure returns (uint256[] memory) {
        // Include all mainnet chains from deployments.json
        uint256[] memory chains = new uint256[](15);
        chains[0] = MAINNET; // Ethereum
        chains[1] = OPTIMISM; // Optimism
        chains[2] = ARBITRUM; // Arbitrum
        chains[3] = POLYGON; // Polygon
        chains[4] = BASE; // Base
        chains[5] = ZK_SYNC; // ZkSync
        chains[6] = LINEA; // Linea
        chains[7] = SCROLL; // Scroll
        chains[8] = BLAST; // Blast
        chains[9] = MODE; // Mode
        chains[10] = ZORA; // Zora
        chains[11] = BSC; // BNB Chain
        chains[12] = 41455; // Aleph Zero (actual chain ID used in deployments.json)
        chains[13] = 232; // Lisk (based on deployments.json)
        chains[14] = 57073; // Redstone (based on deployments.json)
        return chains;
    }

    /**
     * @notice Get SpokePool address from deployments.json
     * @param chainId The chain ID to find the SpokePool for
     * @return The SpokePool address for the given chain, or address(0) if not found
     */
    function getSpokePoolFromDeployments(uint256 chainId) internal view returns (address) {
        string memory json = vm.readFile(DEPLOYMENTS_FILE);
        string memory chainIdStr = vm.toString(chainId);
        string memory queryPath = string.concat(".", chainIdStr, ".SpokePool.address");

        console.log("Looking for SpokePool for chain ID %s", chainIdStr);

        try vm.parseJson(json, queryPath) returns (bytes memory data) {
            address spokePoolAddress = abi.decode(data, (address));
            if (spokePoolAddress != address(0)) {
                console.log("Found SpokePool entry in deployments.json: %s", spokePoolAddress);
                return spokePoolAddress;
            }
        } catch (bytes memory) {
            // Try SVM spoke for Solana-based chains
            try vm.parseJson(json, string.concat(".", chainIdStr, ".SvmSpoke.address")) returns (bytes memory data) {
                address spokePoolAddress = abi.decode(data, (address));
                if (spokePoolAddress != address(0)) {
                    console.log("Found SvmSpoke entry in deployments.json: %s", spokePoolAddress);
                    return spokePoolAddress;
                }
            } catch (bytes memory) {
                console.log("No SpokePool entry found in deployments.json for chain %s", chainIdStr);
            }
        }

        return address(0);
    }
}
