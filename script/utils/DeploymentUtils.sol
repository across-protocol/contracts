// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Config } from "forge-std/Config.sol";
import { Upgrades, Core, UnsafeUpgrades } from "@openzeppelin/foundry-upgrades/src/LegacyUpgrades.sol";
import { Options } from "@openzeppelin/foundry-upgrades/src/Options.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { Constants } from "./Constants.sol";
import { DeployedAddresses } from "./DeployedAddresses.sol";

/**
 * @title DeploymentUtils
 * @notice Foundry smart contract script that provides deployment utilities for Across Protocol contracts
 * @dev This contract implements the equivalent functionality of utils.hre.ts for Foundry scripts
 */
contract DeploymentUtils is Script, Test, Constants, DeployedAddresses, Config {
    // Struct to hold deployment information
    struct DeploymentInfo {
        address hubPool;
        uint256 hubChainId;
        uint256 spokeChainId;
    }

    // Struct to hold deployment result
    struct DeploymentResult {
        address proxy;
        address implementation;
        bool isNewProxy;
    }

    constructor() {
        checkZkStackChain(block.chainid);
    }

    /**
     * @notice Get deployment information for SpokePool deployment
     * @dev This function mimics getSpokePoolDeploymentInfo from utils.hre.ts
     * @param hubPoolAddress The address of the HubPool (can be set via environment variable)
     * @return info Deployment information struct
     */
    function getSpokePoolDeploymentInfo(address hubPoolAddress) public view returns (DeploymentInfo memory info) {
        uint256 spokeChainId = block.chainid;

        // Determine hub chain ID based on spoke chain ID
        uint256 hubChainId;
        if (spokeChainId == getChainId("MAINNET")) {
            hubChainId = getChainId("MAINNET");
        } else if (spokeChainId == getChainId("SEPOLIA")) {
            hubChainId = getChainId("SEPOLIA");
        } else {
            // For L2 chains, hub is typically mainnet or sepolia
            hubChainId = isTestnet(spokeChainId) ? getChainId("SEPOLIA") : getChainId("MAINNET");
        }

        // If hubPoolAddress is not provided, try to get it from environment
        address hubPool = hubPoolAddress;
        if (hubPool == address(0)) {
            hubPool = getAddress(hubChainId, "HubPool");
        }
        console.log("hubPoolAddress", hubPool);

        require(hubPool != address(0), "HubPool address cannot be zero");

        info = DeploymentInfo({ hubPool: hubPool, hubChainId: hubChainId, spokeChainId: spokeChainId });

        console.log("Using chain", hubChainId, "HubPool @", hubPool);
    }

    /**
     * @notice Deploy a new proxy contract or upgrade existing implementation
     * @dev This function mimics deployNewProxy from utils.hre.ts using custom deployment for OpenZeppelin v4
     * @param contractName Name of the contract to deploy
     * @param constructorArgs Constructor arguments for the implementation
     * @param initArgs Initialization arguments for the proxy
     * @param implementationOnly Whether to only deploy implementation (for upgrades)
     * @return result Deployment result struct
     */
    function deployNewProxy(
        string memory contractName,
        bytes memory constructorArgs,
        bytes memory initArgs,
        bool implementationOnly
    ) public returns (DeploymentResult memory result) {
        uint256 chainId = block.chainid;

        contractName = string(abi.encodePacked("contracts/", contractName, ".sol:", contractName));

        // Check if a SpokePool already exists on this chain
        address existingProxy = getDeployedAddress("SpokePool", chainId, false);

        // Determine if we should only deploy implementation
        if (!implementationOnly) {
            implementationOnly = existingProxy != address(0);
        }

        Options memory opts;

        opts.constructorData = constructorArgs;
        // opts.referenceBuildInfoDir = "artifacts";

        if (implementationOnly && existingProxy != address(0)) {
            console.log(
                contractName,
                "deployment already detected @",
                existingProxy,
                ", deploying new implementation."
            );

            // For upgrades, we'll use the prepareUpgrade method from LegacyUpgrades
            address implementation = Core.deploy(contractName, constructorArgs, opts);

            result = DeploymentResult({ proxy: existingProxy, implementation: implementation, isNewProxy: false });

            console.log("New", contractName, "implementation deployed @", implementation);
        } else {
            address implementation = Core.deploy(contractName, constructorArgs, opts);

            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initArgs);

            // For now, return a placeholder result
            result = DeploymentResult({ proxy: address(proxy), implementation: implementation, isNewProxy: true });

            console.log("New", contractName, "proxy deployed @", address(proxy));
            console.log("New", contractName, "implementation deployed @", implementation);
        }

        return result;
    }

    /**
     * @notice Upgrade an existing proxy to a new implementation
     * @param proxyAddress Address of the existing proxy
     * @param contractName Name of the new implementation contract
     * @param constructorArgs Constructor arguments for the new implementation
     * @return newImplementation Address of the new implementation
     */
    function upgradeProxy(
        address proxyAddress,
        string memory contractName,
        bytes memory constructorArgs
    ) public returns (address newImplementation) {
        Options memory opts;
        Upgrades.upgradeProxy(proxyAddress, contractName, constructorArgs, opts);

        // Get the new implementation address
        newImplementation = Upgrades.getImplementationAddress(proxyAddress);

        console.log("Proxy", proxyAddress, "upgraded to implementation @", newImplementation);
        return newImplementation;
    }

    /**
     * @notice Get deployed address from deployments.json
     * @param contractName Name of the contract
     * @param chainId Chain ID
     * @param throwOnError Whether to throw error if not found
     * @return address Deployed contract address
     */
    function getDeployedAddress(
        string memory contractName,
        uint256 chainId,
        bool throwOnError
    ) public view returns (address) {
        // Try to get the address from DeployedAddresses contract
        address deployedAddress = getAddress(chainId, contractName);

        if (deployedAddress == address(0) && throwOnError) {
            revert(string(abi.encodePacked("Contract ", contractName, " not found on chain ", vm.toString(chainId))));
        }

        return deployedAddress;
    }

    /**
     * @notice Check if a chain ID is a testnet
     * @param chainId Chain ID to check
     * @return bool True if testnet
     */
    function isTestnet(uint256 chainId) internal view returns (bool) {
        uint256[] memory testnetChainIds = getTestnetChainIds();
        for (uint256 i = 0; i < testnetChainIds.length; i++) {
            if (chainId == testnetChainIds[i]) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Check if a chain ID is a ZkStack chain
     * @dev This function will revert if the chain ID is a ZkSync chain but the FOUNDRY_PROFILE is not zksync
     * @param chainId Chain ID to check
     */
    function checkZkStackChain(uint256 chainId) internal view {
        bool isZkStackChain = keccak256(abi.encodePacked(getChainFamily(chainId))) ==
            keccak256(abi.encodePacked("ZK_STACK"));

        string memory foundryProfile = vm.envOr("FOUNDRY_PROFILE", string("default"));

        if (isZkStackChain) {
            vm.assertEq(
                foundryProfile,
                string("zksync"),
                "Chain is a ZkStack chain but FOUNDRY_PROFILE is not zksync. Use yarn forge-script-zksync to deploy"
            );
        }
    }
}
