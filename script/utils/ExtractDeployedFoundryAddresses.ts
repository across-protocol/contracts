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

import {
  PUBLIC_NETWORKS,
  PRODUCTION_NETWORKS,
  TEST_NETWORKS,
  MAINNET_CHAIN_IDs,
  TESTNET_CHAIN_IDs,
} from "../../utils/constants";

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
  chains: {
    [chainId: string]: {
      chain_name: string;
      contracts: {
        [contractName: string]: {
          address: string;
          transaction_hash?: string;
          block_number?: number;
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

          let contractName = tx.contractName as string;

          if (contractName === "ERC1967Proxy") {
            contractName = "SpokePool";
          } else if (contractName === "Universal_Adapter") {
            const [, , , cctpDomainId, , oftDstEid] = tx.arguments;

            // Try to find a chain id in TEST_NETWORKS/PRODUCTION_NETWORKS that matches either cctpDomainId or oftDstEid
            let matchingChainId: number | undefined = undefined;

            const networks = broadcastFile.chainId in TEST_NETWORKS ? TEST_NETWORKS : PRODUCTION_NETWORKS;

            for (const [chainIdString, chainInfo] of Object.entries(networks)) {
              const chainId = Number(chainIdString);

              // Some chains may have properties for cctpDomainId or oftDstEid. Try to check both.
              if (
                (chainInfo.cctpDomain !== undefined && chainInfo.cctpDomain?.toString() === cctpDomainId?.toString()) ||
                (chainInfo.oftEid !== undefined && chainInfo.oftEid?.toString() === oftDstEid?.toString())
              ) {
                matchingChainId = chainId;
                break;
              }
            }

            if (matchingChainId !== undefined) {
              contractName = `Universal_Adapter_${matchingChainId}`;
            } else {
              console.log(
                `No chainId found for cctpDomainId (${cctpDomainId}) or oftDstEid (${oftDstEid}) in PUBLIC_NETWORKS`
              );
            }
          }

          contracts.push({
            contractName: contractName || "Unknown",
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
  return PUBLIC_NETWORKS[chainId]?.name || `Chain ${chainId}`;
}

function getBlockExplorerUrl(chainId: number): string | null {
  // Load block explorer from constants.json if available
  try {
    const constantsPath = path.join(process.cwd(), "generated/constants.json");
    if (fs.existsSync(constantsPath)) {
      const constants = JSON.parse(fs.readFileSync(constantsPath, "utf8"));
      const chainInfo = constants.PUBLIC_NETWORKS?.[chainId.toString()];
      if (chainInfo?.blockExplorer) {
        return chainInfo.blockExplorer;
      }
    }
  } catch (error) {
    // Fall through to default handling
  }

  // Fallback: try to get from PUBLIC_NETWORKS if it has blockExplorer
  const network = PUBLIC_NETWORKS[chainId];
  if (network && "blockExplorer" in network) {
    return (network as any).blockExplorer || null;
  }

  return null;
}

function getBlockExplorerAddressUrl(chainId: number, address: string): string {
  const baseUrl = getBlockExplorerUrl(chainId);
  if (!baseUrl) {
    return address; // Return plain address if no explorer available
  }

  // Handle different explorer URL patterns
  if (baseUrl.includes("solscan.io") || baseUrl.includes("explorer.solana.com")) {
    // Solana explorers use different URL format
    return `${baseUrl}/account/${address}`;
  } else {
    // Most EVM explorers use /address/ pattern
    return `${baseUrl}/address/${address}`;
  }
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
      }
    }
  }

  // Generate output content
  const content: string[] = [];
  content.push("# Deployed Contract Addresses");
  content.push("");
  content.push("This file contains the latest deployed smart contract addresses from the broadcast folder.");
  content.push("");

  // Sort by priority: mainnet first, then testnet, then others
  const sortedChainIds = Object.keys(allContracts)
    .map(Number)
    .sort((a, b) => {
      const aIsMainnet = Object.values(MAINNET_CHAIN_IDs).includes(a);
      const bIsMainnet = Object.values(MAINNET_CHAIN_IDs).includes(b);
      const aIsTestnet = Object.values(TESTNET_CHAIN_IDs).includes(a);
      const bIsTestnet = Object.values(TESTNET_CHAIN_IDs).includes(b);

      // Mainnet networks first
      if (aIsMainnet && !bIsMainnet) return -1;
      if (!aIsMainnet && bIsMainnet) return 1;

      // If both are mainnet or both are not mainnet, sort by chain ID
      if (aIsMainnet === bIsMainnet) {
        return a - b;
      }

      // Testnet networks second
      if (aIsTestnet && !bIsTestnet) return -1;
      if (!aIsTestnet && bIsTestnet) return 1;

      // If both are testnet or both are not testnet, sort by chain ID
      if (aIsTestnet === bIsTestnet) {
        return a - b;
      }

      // Default sort by chain ID
      return a - b;
    });

  for (const chainId of sortedChainIds) {
    const chainInfo = allContracts[chainId];

    const chainNameFormatted = `${chainInfo.chainName} (${chainId})`;

    content.push(`## ${chainNameFormatted}`);
    content.push("");

    // Collect all contracts for this chain into a single array
    const allChainContracts: Contract[] = [];
    for (const contracts of Object.values(chainInfo.scripts)) {
      allChainContracts.push(...contracts);
    }

    // Sort contracts by name for consistent ordering
    allChainContracts.sort((a, b) => a.contractName.localeCompare(b.contractName));

    if (allChainContracts.length > 0) {
      // Generate table header
      content.push("| Contract Name | Address |");
      content.push("| ------------- | ------- |");

      // Generate table rows
      for (const contract of allChainContracts) {
        const address = toChecksumAddress(contract.contractAddress);
        const explorerUrl = getBlockExplorerAddressUrl(chainId, address);
        const addressLink = explorerUrl !== address ? `[${address}](${explorerUrl})` : address;

        content.push(`| ${contract.contractName} | ${addressLink} |`);
      }
      content.push("");
    }
  }

  // Generate JSON format as well
  const jsonOutput: JsonOutput = {
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
          ...(contract.blockNumber !== null && { block_number: contract.blockNumber }),
          ...(contract.transactionHash !== "Unknown" && { transaction_hash: contract.transactionHash }),
        };
      }
    }
  }

  // Write markdown file
  const markdownFile = outputFile.replace(/\.[^/.]+$/, ".md");
  fs.writeFileSync(markdownFile, content.join("\n"));

  // Write JSON file
  const jsonFile = outputFile.replace(/\.[^/.]+$/, ".json");
  fs.writeFileSync(jsonFile, JSON.stringify(jsonOutput, null, 2) + "\n");

  console.log("Generated deployed addresses files:");
  console.log(`  - Markdown: ${markdownFile}`);
  console.log(`  - JSON: ${jsonFile}`);
}

function main(): void {
  // Get the script directory and find broadcast folder
  const scriptDir = path.dirname(__filename);
  const projectRoot = path.dirname(scriptDir);
  const broadcastDir = path.join(projectRoot, "..", "broadcast");
  const deploymentsDir = path.join(projectRoot, "..", "deployments");

  if (!fs.existsSync(broadcastDir)) {
    console.error(`Error: Broadcast directory not found at ${broadcastDir}`);
    process.exit(1);
  }

  console.log(`Scanning broadcast directory: ${broadcastDir}`);
  console.log(`Scanning deployments directory: ${deploymentsDir}`);

  // Read deployments.json
  const deploymentsFiles = readDeploymentsFile(deploymentsDir);

  // Find all broadcast files
  const broadcastFiles = findBroadcastFiles(broadcastDir);

  // Combine both sources (order is important, deployments.json should be first)
  const allFiles = [...deploymentsFiles, ...broadcastFiles];

  if (allFiles.length === 0) {
    console.error("No run-latest.json files found in broadcast directory and no deployments.json found");
    process.exit(1);
  }

  console.log(`Found ${broadcastFiles.length} broadcast files and ${deploymentsFiles.length} deployment entries:`);

  // Generate output files inside broadcast directory
  const outputFile = path.join(broadcastDir, "deployed-addresses.json");
  generateAddressesFile(allFiles, outputFile);

  console.log("\nDone!");
}

if (require.main === module) {
  main();
}
