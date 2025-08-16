// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/StdJson.sol";
import "forge-std/Test.sol";

/**
 * @title DeployedAddresses
 * @notice This contract contains all deployed contract addresses from Foundry broadcast files
 * @dev Generated on: 2025-08-14T16:09:40.061Z
 * @dev This file is auto-generated. Do not edit manually.
 * @dev Uses Foundry's parseJson functionality for scripts/tests only (not for on-chain use)
 */
contract DeployedAddresses is Test {
    using stdJson for string;

    // Path to the JSON file containing deployed addresses
    string private constant JSON_PATH = "broadcast/deployed-addresses.json";

    /**
     * @notice Get contract address by chain ID and contract name
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return The contract address
     */
    function getAddress(uint256 chainId, string memory contractName) public view returns (address) {
        string memory jsonData = vm.readFile(JSON_PATH);
        string memory path = string.concat(
            '.chains["',
            vm.toString(chainId),
            '"].contracts["',
            contractName,
            '"].address'
        );
        return jsonData.readAddress(path);
    }

    /**
     * @notice Check if a contract exists for the given chain ID and name
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return True if the contract exists, false otherwise
     */
    function hasAddress(uint256 chainId, string memory contractName) public view returns (bool) {
        return getAddress(chainId, contractName) != address(0);
    }

    /**
     * @notice Get transaction hash for a contract
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return The transaction hash
     */
    function getTransactionHash(uint256 chainId, string memory contractName) public view returns (string memory) {
        string memory jsonData = vm.readFile(JSON_PATH);
        string memory path = string.concat(
            '.chains["',
            vm.toString(chainId),
            '"].contracts["',
            contractName,
            '"].transaction_hash'
        );
        return jsonData.readString(path);
    }

    /**
     * @notice Get block number for a contract deployment
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return The block number
     */
    function getBlockNumber(uint256 chainId, string memory contractName) public view returns (uint256) {
        string memory jsonData = vm.readFile(JSON_PATH);
        string memory path = string.concat(
            '.chains["',
            vm.toString(chainId),
            '"].contracts["',
            contractName,
            '"].block_number'
        );
        return jsonData.readUint(path);
    }

    /**
     * @notice Get chain name for a given chain ID
     * @param chainId The chain ID
     * @return The chain name
     */
    function getChainName(uint256 chainId) public view returns (string memory) {
        string memory jsonData = vm.readFile(JSON_PATH);
        string memory path = string.concat('.chains["', vm.toString(chainId), '"].chain_name');
        return jsonData.readString(path);
    }

    /**
     * @notice Get all contract names for a given chain ID
     * @param chainId The chain ID
     * @return Array of contract names
     */
    function getContractNames(uint256 chainId) public view returns (string[] memory) {
        string memory jsonData = vm.readFile(JSON_PATH);
        string memory path = string.concat('.chains["', vm.toString(chainId), '"].contracts | keys');
        return jsonData.readStringArray(path);
    }

    /**
     * @notice Get all chain IDs
     * @return Array of chain IDs
     */
    function getChainIds() public view returns (uint256[] memory) {
        string memory jsonData = vm.readFile(JSON_PATH);
        string[] memory chainIdStrings = jsonData.readStringArray(".chains | keys");
        uint256[] memory chainIds = new uint256[](chainIdStrings.length);
        for (uint256 i = 0; i < chainIdStrings.length; i++) {
            chainIds[i] = vm.parseUint(chainIdStrings[i]);
        }
        return chainIds;
    }

    /**
     * @notice Get the generation timestamp of the JSON file
     * @return The generation timestamp
     */
    function getGeneratedAt() public view returns (string memory) {
        string memory jsonData = vm.readFile(JSON_PATH);
        return jsonData.readString(".generated_at");
    }

    /**
     * @notice Get contract info for a specific contract
     * @param chainId The chain ID
     * @param contractName The contract name
     * @return addr The contract address
     * @return txHash The transaction hash
     * @return blockNum The block number
     */
    function getContractInfo(
        uint256 chainId,
        string memory contractName
    ) public view returns (address addr, string memory txHash, uint256 blockNum) {
        addr = getAddress(chainId, contractName);
        txHash = getTransactionHash(chainId, contractName);
        blockNum = getBlockNumber(chainId, contractName);
    }
}
