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

import { PUBLIC_NETWORKS, MAINNET_CHAIN_IDs, TESTNET_CHAIN_IDs } from "../../utils/constants";

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

          let contractName = tx.contractName as string;

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

  // Log the sorting priority for visibility
  console.log("\nChain sorting priority:");
  const mainnetChains = sortedChainIds.filter((id) => Object.values(MAINNET_CHAIN_IDs).includes(id));
  const testnetChains = sortedChainIds.filter((id) => Object.values(TESTNET_CHAIN_IDs).includes(id));
  const otherChains = sortedChainIds.filter(
    (id) => !Object.values(MAINNET_CHAIN_IDs).includes(id) && !Object.values(TESTNET_CHAIN_IDs).includes(id)
  );

  console.log(
    `  Mainnet chains (${mainnetChains.length}): ${mainnetChains.map((id) => `${getChainName(id)}(${id})`).join(", ")}`
  );
  console.log(
    `  Testnet chains (${testnetChains.length}): ${testnetChains.map((id) => `${getChainName(id)}(${id})`).join(", ")}`
  );
  console.log(
    `  Other chains (${otherChains.length}): ${otherChains.map((id) => `${getChainName(id)}(${id})`).join(", ")}`
  );
  console.log("");

  for (const chainId of sortedChainIds) {
    const chainInfo = allContracts[chainId];
    const isMainnet = Object.values(MAINNET_CHAIN_IDs).includes(chainId);
    const isTestnet = Object.values(TESTNET_CHAIN_IDs).includes(chainId);

    // Add section headers only once at the beginning of each category
    if (
      isMainnet &&
      (chainId === sortedChainIds[0] ||
        (sortedChainIds.indexOf(chainId) > 0 &&
          !Object.values(MAINNET_CHAIN_IDs).includes(sortedChainIds[sortedChainIds.indexOf(chainId) - 1])))
    ) {
      content.push("## 🚀 Mainnet Networks");
      content.push("");
    } else if (
      isTestnet &&
      !isMainnet &&
      (chainId === sortedChainIds[0] ||
        (sortedChainIds.indexOf(chainId) > 0 &&
          Object.values(MAINNET_CHAIN_IDs).includes(sortedChainIds[sortedChainIds.indexOf(chainId) - 1]) &&
          !Object.values(TESTNET_CHAIN_IDs).includes(sortedChainIds[sortedChainIds.indexOf(chainId) - 1])))
    ) {
      content.push("## 🧪 Testnet Networks");
      content.push("");
    } else if (
      !isMainnet &&
      !isTestnet &&
      (chainId === sortedChainIds[0] ||
        (sortedChainIds.indexOf(chainId) > 0 &&
          Object.values(MAINNET_CHAIN_IDs).includes(sortedChainIds[sortedChainIds.indexOf(chainId) - 1]) &&
          Object.values(TESTNET_CHAIN_IDs).includes(sortedChainIds[sortedChainIds.indexOf(chainId) - 1])))
    ) {
      content.push("## 🔗 Other Networks");
      content.push("");
    }

    content.push(`### ${chainInfo.chainName} (Chain ID: ${chainId})`);
    content.push("");

    for (const [scriptName, contracts] of Object.entries(chainInfo.scripts)) {
      const name = contracts.length > 1 ? contracts[0].contractName : scriptName;
      content.push(`#### ${name}`);
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
  console.log("Project root:", projectRoot);
  console.log("Script dir:", scriptDir);
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
  for (const bf of allFiles) {
    const source = bf.isDeploymentsJson ? "deployments.json" : "broadcast";
    console.log(`  - ${bf.scriptName} on ${getChainName(bf.chainId)} (from ${source})`);
  }

  // Generate output files inside broadcast directory
  const outputFile = path.join(broadcastDir, "deployed-addresses.json");
  generateAddressesFile(allFiles, outputFile);

  console.log("\nDone!");
}

if (require.main === module) {
  main();
}
