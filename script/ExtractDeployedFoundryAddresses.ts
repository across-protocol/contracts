#!/usr/bin/env node
/**
 * Script to extract deployed contract addresses from Foundry broadcast files.
 *
 * This script reads from the broadcast folder and generates a file with the latest deployed
 * smart contract addresses that are in the broadcast folder.
 *
 * It specifically looks at the run-latest.json file for each smart contract and inside
 * that JSON looks at the `contractAddress` field.
 */

import * as fs from "fs";
import * as path from "path";
import { getAddress } from "ethers/lib/utils";

interface BroadcastFile {
  scriptName: string;
  chainId: number;
  filePath: string;
  isDeploymentsJson?: boolean;
  deploymentsData?: any;
}

interface Contract {
  contractName: string;
  contractAddress: string;
  transactionHash: string;
  blockNumber: number | null;
}

interface ChainInfo {
  chainName: string;
  scripts: { [scriptName: string]: Contract[] };
}

interface AllContracts {
  [chainId: number]: ChainInfo;
}

interface JsonOutput {
  generated_at: string;
  chains: {
    [chainId: string]: {
      chain_name: string;
      contracts: {
        [contractName: string]: {
          address: string;
          transaction_hash: string;
          block_number: number | null;
        };
      };
    };
  };
}

function findBroadcastFiles(broadcastDir: string): BroadcastFile[] {
  const broadcastFiles: BroadcastFile[] = [];

  try {
    const scriptDirs = fs.readdirSync(broadcastDir);

    for (const scriptDir of scriptDirs) {
      const scriptPath = path.join(broadcastDir, scriptDir);
      const stat = fs.statSync(scriptPath);

      if (stat.isDirectory()) {
        // Each script has its own directory (e.g., DeployHubPool.s.sol)
        const chainDirs = fs.readdirSync(scriptPath);

        for (const chainDir of chainDirs) {
          const chainPath = path.join(scriptPath, chainDir);
          const chainStat = fs.statSync(chainPath);

          if (chainStat.isDirectory() && /^\d+$/.test(chainDir)) {
            // Chain ID directories (e.g., 11155111 for Sepolia)
            const runLatestPath = path.join(chainPath, "run-latest.json");

            if (fs.existsSync(runLatestPath)) {
              broadcastFiles.push({
                scriptName: scriptDir,
                chainId: parseInt(chainDir),
                filePath: runLatestPath,
              });
            }
          }
        }
      }
    }
  } catch (error) {
    console.error(`Error reading broadcast directory: ${error}`);
  }

  return broadcastFiles;
}

function readDeploymentsFile(deploymentsDir: string): BroadcastFile[] {
  const deploymentsFiles: BroadcastFile[] = [];

  try {
    const deploymentsPath = path.join(deploymentsDir, "deployments.json");

    if (fs.existsSync(deploymentsPath)) {
      const data = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));

      for (const [chainId, contracts] of Object.entries(data)) {
        if (typeof contracts === "object" && contracts !== null) {
          // Create a virtual broadcast file for deployments.json
          deploymentsFiles.push({
            scriptName: "DeploymentsJson",
            chainId: parseInt(chainId),
            filePath: deploymentsPath,
            isDeploymentsJson: true,
            deploymentsData: contracts as any,
          });
        }
      }
    }
  } catch (error) {
    console.error(`Error reading deployments.json: ${error}`);
  }

  return deploymentsFiles;
}

function extractContractAddresses(broadcastFile: BroadcastFile): Contract[] {
  if (broadcastFile.isDeploymentsJson && broadcastFile.deploymentsData) {
    // Handle deployments.json format
    const contracts: Contract[] = [];
    const deploymentsData = broadcastFile.deploymentsData;

    for (const [contractName, contractInfo] of Object.entries(deploymentsData)) {
      if (typeof contractInfo === "object" && contractInfo !== null && "address" in contractInfo) {
        const info = contractInfo as any;
        contracts.push({
          contractName: contractName,
          contractAddress: info.address,
          transactionHash: info.transactionHash || "Unknown",
          blockNumber: info.blockNumber || null,
        });
      }
    }

    return contracts;
  } else {
    // Handle broadcast file format
    try {
      const data = JSON.parse(fs.readFileSync(broadcastFile.filePath, "utf8"));
      const contracts: Contract[] = [];
      const transactions = data.transactions || [];
      const receipts = data.receipts || [];

      // Create a mapping of transaction hash to block number
      const txHashToBlock: { [hash: string]: number } = {};
      for (const receipt of receipts) {
        const txHash = receipt.transactionHash;
        let blockNumber = receipt.blockNumber;
        if (txHash && blockNumber) {
          // Convert hex to decimal
          if (typeof blockNumber === "string" && blockNumber.startsWith("0x")) {
            blockNumber = parseInt(blockNumber, 16);
          }
          txHashToBlock[txHash] = blockNumber;
        }
      }

      for (const tx of transactions) {
        if (tx.transactionType === "CREATE" && tx.contractAddress) {
          const txHash = tx.hash;
          const blockNumber = txHashToBlock[txHash] || null;

          contracts.push({
            contractName: tx.contractName || "Unknown",
            contractAddress: tx.contractAddress,
            transactionHash: txHash,
            blockNumber: blockNumber,
          });
        }
      }

      return contracts;
    } catch (error) {
      console.error(`Error reading ${broadcastFile.filePath}: ${error}`);
      return [];
    }
  }
}

function getChainName(chainId: number): string {
  const chainNames: { [id: number]: string } = {
    1: "Mainnet",
    11155111: "Sepolia",
    42161: "Arbitrum One",
    421614: "Arbitrum Sepolia",
    137: "Polygon",
    80002: "Polygon Amoy",
    10: "Optimism",
    11155420: "Optimism Sepolia",
    8453: "Base",
    84532: "Base Sepolia",
    56: "BSC",
    324: "zkSync Era",
    59144: "Linea",
    534352: "Scroll",
    534351: "Scroll Sepolia",
    81457: "Blast",
    168587773: "Blast Sepolia",
    // Add more chain IDs as needed
  };
  return chainNames[chainId] || `Chain ${chainId}`;
}

function toChecksumAddress(address: string): string {
  // Check if this looks like an Ethereum address (0x followed by 40 hex characters)
  if (/^0x[a-fA-F0-9]{40}$/.test(address)) {
    // Use ethers.js to get the checksummed address for valid Ethereum addresses
    try {
      return getAddress(address);
    } catch (error) {
      // If ethers validation fails, return the original address
      console.warn(`Warning: Invalid Ethereum address format: ${address}`);
      return address;
    }
  } else {
    // For non-Ethereum addresses (like Solana), return as-is
    return address;
  }
}

function sanitizeContractName(name: string): string {
  // Remove special characters and replace with underscores
  let sanitized = name.replace(/[^a-zA-Z0-9]/g, "_");
  // Remove multiple consecutive underscores
  sanitized = sanitized.replace(/_+/g, "_");
  // Remove leading/trailing underscores
  sanitized = sanitized.replace(/^_+|_+$/g, "");
  // Ensure it starts with a letter
  if (sanitized && /^\d/.test(sanitized)) {
    sanitized = "CONTRACT_" + sanitized;
  }
  return sanitized.toUpperCase();
}

function generateFoundryScript(broadcastFiles: BroadcastFile[], outputFile: string): void {
  const allContracts: AllContracts = {};

  // Process each broadcast file
  for (const broadcastFile of broadcastFiles) {
    const contracts = extractContractAddresses(broadcastFile);

    if (contracts.length > 0) {
      const chainId = broadcastFile.chainId;
      const chainName = getChainName(chainId);
      // For deployments.json, use contract name as scriptName for each contract
      if (broadcastFile.isDeploymentsJson) {
        for (const contract of contracts) {
          const scriptName = contract.contractName;
          if (!allContracts[chainId]) {
            allContracts[chainId] = {
              chainName: chainName,
              scripts: {},
            };
          }
          allContracts[chainId].scripts[scriptName] = [contract];
          console.log(`Added deployments.json contract ${contract.contractName} on ${chainName}`);
        }
      } else {
        const scriptName = broadcastFile.scriptName;
        if (!allContracts[chainId]) {
          allContracts[chainId] = {
            chainName: chainName,
            scripts: {},
          };
        }
        allContracts[chainId].scripts[scriptName] = contracts;
        console.log(`Added ${contracts.length} contracts from ${scriptName} on ${chainName}`);
      }
    }
  }

  // Generate Solidity contract content
  const content: string[] = [];
  content.push("// SPDX-License-Identifier: MIT");
  content.push("pragma solidity ^0.8.19;");
  content.push("");
  content.push("/**");
  content.push(" * @title DeployedAddresses");
  content.push(" * @notice This contract contains all deployed contract addresses from Foundry broadcast files");
  content.push(` * @dev Generated on: ${new Date().toISOString()}`);
  content.push(" * @dev This file is auto-generated. Do not edit manually.");
  content.push(" */");
  content.push("contract DeployedAddresses {");
  content.push("");

  // Generate mapping for dynamic lookup
  content.push("    // Mapping for dynamic address lookup");
  content.push("    // chainId => contractName => address");
  content.push("    mapping(uint256 => mapping(string => address)) private _addresses;");
  content.push("");

  // Sort by chain ID for consistent output
  const sortedChainIds = Object.keys(allContracts)
    .map(Number)
    .sort((a, b) => a - b);

  for (const chainId of sortedChainIds) {
    const chainInfo = allContracts[chainId];
    const chainNameSafe = chainInfo.chainName.replace(/[ -]/g, "_").toUpperCase();

    content.push(`    // ${chainInfo.chainName} (Chain ID: ${chainId})`);
    content.push("");

    for (const [scriptName, contracts] of Object.entries(chainInfo.scripts)) {
      const scriptNameSafe = scriptName
        .replace(/\.s\.sol$/, "")
        .replace(/\.sol$/, "")
        .toUpperCase();
      content.push(`    // ${scriptName}`);

      for (const contract of contracts) {
        const contractNameSafe = sanitizeContractName(contract.contractName);
        let address = contract.contractAddress;
        // Convert to checksum address
        try {
          address = toChecksumAddress(address);
        } catch (error) {
          // Keep original address if conversion fails
        }

        // Skip non-Ethereum addresses (like Solana addresses) for Solidity contracts
        if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
          console.log(`Skipping non-Ethereum address for Solidity: ${contract.contractName} = ${address}`);
          continue;
        }

        // Create a descriptive constant name - use immutable instead of constant
        const constantName = `${chainNameSafe}_${scriptNameSafe}_${contractNameSafe}`;
        content.push(`    address public immutable ${constantName};`);
      }

      content.push("");
    }

    content.push("");
  }

  // Generate constructor to populate the mapping and immutable variables
  content.push("    constructor() {");
  content.push("        // Initialize the address mapping");

  for (const chainId of sortedChainIds) {
    const chainInfo = allContracts[chainId];
    content.push(`        // ${chainInfo.chainName} (Chain ID: ${chainId})`);

    for (const [scriptName, contracts] of Object.entries(chainInfo.scripts)) {
      for (const contract of contracts) {
        const contractName = contract.contractName;
        let address = contract.contractAddress;
        try {
          address = toChecksumAddress(address);
        } catch (error) {
          // Keep original address if conversion fails
        }

        // Skip non-Ethereum addresses for Solidity contracts
        if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
          continue;
        }

        content.push(`        _addresses[${chainId}]["${contractName}"] = ${address};`);
      }
    }

    content.push("");
  }

  // Initialize immutable variables
  content.push("        // Initialize immutable variables");

  for (const chainId of sortedChainIds) {
    const chainInfo = allContracts[chainId];
    const chainNameSafe = chainInfo.chainName.replace(/[ -]/g, "_").toUpperCase();

    for (const [scriptName, contracts] of Object.entries(chainInfo.scripts)) {
      const scriptNameSafe = scriptName
        .replace(/\.s\.sol$/, "")
        .replace(/\.sol$/, "")
        .toUpperCase();

      for (const contract of contracts) {
        const contractNameSafe = sanitizeContractName(contract.contractName);
        let address = contract.contractAddress;
        try {
          address = toChecksumAddress(address);
        } catch (error) {
          // Keep original address if conversion fails
        }

        // Skip non-Ethereum addresses for Solidity contracts
        if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
          continue;
        }

        const constantName = `${chainNameSafe}_${scriptNameSafe}_${contractNameSafe}`;
        content.push(`        ${constantName} = ${address};`);
      }
    }
  }

  content.push("    }");
  content.push("");

  content.push("    /**");
  content.push("     * @notice Get contract address by chain ID and contract name");
  content.push("     * @param chainId The chain ID");
  content.push("     * @param contractName The contract name");
  content.push("     * @return The contract address");
  content.push("     */");
  content.push("    function getAddress(uint256 chainId, string memory contractName) public view returns (address) {");
  content.push("        return _addresses[chainId][contractName];");
  content.push("    }");
  content.push("");

  content.push("    /**");
  content.push("     * @notice Check if a contract exists for the given chain ID and name");
  content.push("     * @param chainId The chain ID");
  content.push("     * @param contractName The contract name");
  content.push("     * @return True if the contract exists, false otherwise");
  content.push("     */");
  content.push("    function hasAddress(uint256 chainId, string memory contractName) public view returns (bool) {");
  content.push("        return _addresses[chainId][contractName] != address(0);");
  content.push("    }");
  content.push("}");

  // Write Solidity file
  const solidityFile = outputFile.replace(/\.[^/.]+$/, ".sol");
  fs.writeFileSync(solidityFile, content.join("\n"));

  console.log(`Generated Foundry script: ${solidityFile}`);
}

function generateAddressesFile(broadcastFiles: BroadcastFile[], outputFile: string): void {
  const allContracts: AllContracts = {};

  // Process each broadcast file
  for (const broadcastFile of broadcastFiles) {
    const contracts = extractContractAddresses(broadcastFile);

    if (contracts.length > 0) {
      const chainId = broadcastFile.chainId;
      const chainName = getChainName(chainId);
      // For deployments.json, use contract name as scriptName for each contract
      if (broadcastFile.isDeploymentsJson) {
        for (const contract of contracts) {
          const scriptName = contract.contractName;
          if (!allContracts[chainId]) {
            allContracts[chainId] = {
              chainName: chainName,
              scripts: {},
            };
          }
          allContracts[chainId].scripts[scriptName] = [contract];
          console.log(`Added deployments.json contract ${contract.contractName} on ${chainName}`);
        }
      } else {
        const scriptName = broadcastFile.scriptName;
        if (!allContracts[chainId]) {
          allContracts[chainId] = {
            chainName: chainName,
            scripts: {},
          };
        }
        allContracts[chainId].scripts[scriptName] = contracts;
        console.log(`Added ${contracts.length} contracts from ${scriptName} on ${chainName}`);
      }
    }
  }

  // Generate output content
  const content: string[] = [];
  content.push("# Deployed Contract Addresses");
  content.push("");
  content.push(`Generated on: ${new Date().toISOString()}`);
  content.push("");
  content.push("This file contains the latest deployed smart contract addresses from the broadcast folder.");
  content.push("");

  // Sort by chain ID for consistent output
  const sortedChainIds = Object.keys(allContracts)
    .map(Number)
    .sort((a, b) => a - b);

  for (const chainId of sortedChainIds) {
    const chainInfo = allContracts[chainId];
    content.push(`## ${chainInfo.chainName} (Chain ID: ${chainId})`);
    content.push("");

    for (const [scriptName, contracts] of Object.entries(chainInfo.scripts)) {
      content.push(`### ${scriptName}`);
      content.push("");

      for (const contract of contracts) {
        content.push(`- **${contract.contractName}**: \`${contract.contractAddress}\``);
        content.push(`  - Transaction Hash: \`${contract.transactionHash}\``);
        if (contract.blockNumber !== null) {
          content.push(`  - Block Number: \`${contract.blockNumber}\``);
        }
        content.push("");
      }
    }

    content.push("");
  }

  // Generate JSON format as well
  const jsonOutput: JsonOutput = {
    generated_at: new Date().toISOString(),
    chains: {},
  };

  for (const [chainId, chainInfo] of Object.entries(allContracts)) {
    jsonOutput.chains[chainId] = {
      chain_name: chainInfo.chainName,
      contracts: {},
    };

    for (const [scriptName, contracts] of Object.entries(chainInfo.scripts)) {
      for (const contract of contracts as Contract[]) {
        const contractName = contract.contractName;
        jsonOutput.chains[chainId].contracts[contractName] = {
          address: contract.contractAddress,
          transaction_hash: contract.transactionHash,
          block_number: contract.blockNumber,
        };
      }
    }
  }

  // Write markdown file
  const markdownFile = outputFile.replace(/\.[^/.]+$/, ".md");
  fs.writeFileSync(markdownFile, content.join("\n"));

  // Write JSON file
  const jsonFile = outputFile.replace(/\.[^/.]+$/, ".json");
  fs.writeFileSync(jsonFile, JSON.stringify(jsonOutput, null, 2));

  console.log("Generated deployed addresses files:");
  console.log(`  - Markdown: ${markdownFile}`);
  console.log(`  - JSON: ${jsonFile}`);
}

function main(): void {
  // Get the script directory and find broadcast folder
  const scriptDir = path.dirname(__filename);
  const projectRoot = path.dirname(scriptDir);
  const broadcastDir = path.join(projectRoot, "broadcast");
  const deploymentsDir = path.join(projectRoot, "deployments");

  if (!fs.existsSync(broadcastDir)) {
    console.error(`Error: Broadcast directory not found at ${broadcastDir}`);
    process.exit(1);
  }

  console.log(`Scanning broadcast directory: ${broadcastDir}`);
  console.log(`Scanning deployments directory: ${deploymentsDir}`);

  // Find all broadcast files
  const broadcastFiles = findBroadcastFiles(broadcastDir);

  // Read deployments.json
  const deploymentsFiles = readDeploymentsFile(deploymentsDir);

  // Combine both sources
  const allFiles = [...broadcastFiles, ...deploymentsFiles];

  if (allFiles.length === 0) {
    console.error("No run-latest.json files found in broadcast directory and no deployments.json found");
    process.exit(1);
  }

  console.log(`Found ${broadcastFiles.length} broadcast files and ${deploymentsFiles.length} deployment entries:`);
  for (const bf of allFiles) {
    const source = bf.isDeploymentsJson ? "deployments.json" : "broadcast";
    console.log(`  - ${bf.scriptName} on ${getChainName(bf.chainId)} (from ${source})`);
  }

  // Generate output files inside broadcast directory
  const outputFile = path.join(broadcastDir, "deployed-addresses.json");
  generateAddressesFile(allFiles, outputFile);

  // Generate Foundry script
  const scriptOutputFile = path.join(broadcastDir, "DeployedAddresses.sol");
  generateFoundryScript(allFiles, scriptOutputFile);

  console.log("\nDone!");
}

if (require.main === module) {
  main();
}
