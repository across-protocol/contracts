/**
 * Script to extract deployed contract addresses from Foundry broadcast files.
 *
 * This script reads from the broadcast folder and generates a file with the latest deployed
 * smart contract addresses that are in the broadcast folder.
 *
 * It specifically looks at the run-latest.json file for each smart contract and inside
 * that JSON looks at the `contractAddress` field. Multi-chain broadcasts (broadcast/multi/
 * <Script>.s.sol-latest/run.json) are also scanned; each per-chain deployment element inside
 * them is processed exactly like a single-chain run-latest.json.
 */

import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
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
  // For multi-chain broadcasts: the per-chain deployment element from broadcast/multi/*/run.json,
  // shaped identically to a single-chain run-latest.json.
  multiRunData?: any;
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

/**
 * `ERC1967Proxy` is a generic contract name, so the broadcast can't tell us what a given proxy *is*.
 * Historically every proxy in this repo was a SpokePool, so the extractor blanket-labeled them "SpokePool".
 * Now other stacks deploy their own proxies (e.g. the counterfactual beacon), so we disambiguate by the
 * deploying script: an explicit mapping here wins, otherwise SpokePool-named scripts → "SpokePool",
 * otherwise a name derived from the script.
 */
const PROXY_LOGICAL_NAME_BY_SCRIPT: Record<string, string> = {
  "DeployCounterfactualBeacon.s.sol": "CounterfactualBeacon",
  // The multi-chain beacon-stack deploy stands up the same logical contract, so it records under the same
  // key: whichever ran most recently is the canonical `CounterfactualBeacon` for the chain.
  "DeployCounterfactualBeaconStack.s.sol": "CounterfactualBeacon",
};

/** Scripts whose deployed ERC1967Proxy is the canonical Across SpokePool (e.g. DeployBaseSpokePool.s.sol). */
function isSpokePoolDeployScript(scriptName: string): boolean {
  return /SpokePool\.s\.sol$/.test(scriptName);
}

/**
 * Get the git repository root directory.
 */
function getGitRoot(): string {
  const output = execSync("git rev-parse --show-toplevel", { encoding: "utf8" });
  return output.trim();
}

/**
 * Get a set of files that are tracked by git (committed or staged).
 * This excludes untracked local files that haven't been staged.
 */
function getTrackedFiles(directory: string): Set<string> {
  const gitRoot = getGitRoot();
  const relativeDir = path.relative(gitRoot, directory);

  // git ls-files returns files that are in the index (committed or staged)
  const output = execSync(`git ls-files "${relativeDir}"`, {
    encoding: "utf8",
    cwd: gitRoot,
  });

  return new Set(
    output
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((f) => path.resolve(gitRoot, f))
  );
}

/**
 * Read a destination chain id that a deploy script returned (e.g. DeployUniversalAdapter.s.sol).
 * Foundry records a script's return values in the broadcast file's top-level `returns`. The key is the
 * return variable's name when it is named (e.g. "destinationChainId") and its positional index ("0")
 * otherwise, so we check the named key, then "0", then fall back to the sole entry. The numeric guard
 * ignores non-chain-id returns (e.g. an address), so callers safely fall back to the legacy matching.
 */
function getReturnedDestinationChainId(data: any): string | undefined {
  const returns = data?.returns;
  if (!returns || typeof returns !== "object") return undefined;
  const keys = Object.keys(returns);
  const value =
    returns["destinationChainId"]?.value ??
    returns["0"]?.value ??
    (keys.length === 1 ? returns[keys[0]]?.value : undefined);
  return typeof value === "string" && /^\d+$/.test(value) ? value : undefined;
}

function findBroadcastFiles(broadcastDir: string): BroadcastFile[] {
  const broadcastFiles: BroadcastFile[] = [];

  // Get set of files tracked by git (committed or staged)
  const trackedFiles = getTrackedFiles(broadcastDir);

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
            const resolvedPath = path.resolve(runLatestPath);

            // Only include files that exist AND are tracked by git (committed or staged)
            if (fs.existsSync(runLatestPath) && trackedFiles.has(resolvedPath)) {
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

/**
 * Find multi-chain broadcast sequences (broadcast/multi/<Script>.s.sol-latest/run.json). Forge writes
 * these instead of per-chain run-latest.json files when a script broadcasts to several chains in one
 * run. Each element of the sequence's `deployments` array has the same shape as a single-chain
 * run-latest.json, so each becomes a virtual broadcast file for its chain.
 *
 * NB: forge replaces the whole -latest folder on every rerun that broadcasts to two or more chains,
 * so chains skipped by an idempotent rerun vanish from it. materializeMultiBroadcasts() persists each
 * element into the durable per-chain layout to protect against that.
 */
function findMultiBroadcastFiles(broadcastDir: string): BroadcastFile[] {
  const multiDir = path.join(broadcastDir, "multi");
  if (!fs.existsSync(multiDir)) return [];

  const broadcastFiles: BroadcastFile[] = [];
  const trackedFiles = getTrackedFiles(broadcastDir);

  try {
    for (const seqDir of fs.readdirSync(multiDir)) {
      // Only the -latest sequence counts (timestamped siblings and dry-run are historical/simulated).
      const match = seqDir.match(/^(.+?\.s\.sol).*-latest$/);
      const runJsonPath = path.join(multiDir, seqDir, "run.json");

      // Only include files that exist AND are tracked by git (committed or staged)
      if (!match || !fs.existsSync(runJsonPath) || !trackedFiles.has(path.resolve(runJsonPath))) continue;

      const data = JSON.parse(fs.readFileSync(runJsonPath, "utf8"));
      for (const deployment of data.deployments ?? []) {
        if (typeof deployment.chain !== "number") continue;
        broadcastFiles.push({
          scriptName: match[1],
          chainId: deployment.chain,
          filePath: runJsonPath,
          multiRunData: deployment,
        });
      }
    }
  } catch (error) {
    console.error(`Error reading multi broadcast directory: ${error}`);
  }

  return broadcastFiles;
}

/**
 * Materialize each multi-chain deployment element into forge's canonical per-chain layout
 * (broadcast/<script>/<chainId>/run-latest.json — identical schema). The multi -latest folder is
 * volatile (see findMultiBroadcastFiles), so the per-chain layout is the durable record: a rerun can
 * never erase a chain it didn't touch. Existing per-chain files are only replaced when the multi
 * element is newer (forge timestamps both in milliseconds).
 */
function materializeMultiBroadcasts(broadcastDir: string, multiFiles: BroadcastFile[]): void {
  // Keep only the newest element per (script, chain) in case several sequences overlap.
  const newest = new Map<string, BroadcastFile>();
  for (const file of multiFiles) {
    const key = `${file.scriptName}/${file.chainId}`;
    const prev = newest.get(key);
    if (!prev || (file.multiRunData.timestamp ?? 0) > (prev.multiRunData.timestamp ?? 0)) {
      newest.set(key, file);
    }
  }

  const written: string[] = [];
  for (const file of newest.values()) {
    const chainDir = path.join(broadcastDir, file.scriptName, String(file.chainId));
    const target = path.join(chainDir, "run-latest.json");
    if (fs.existsSync(target)) {
      try {
        const existing = JSON.parse(fs.readFileSync(target, "utf8"));
        if ((existing.timestamp ?? 0) >= (file.multiRunData.timestamp ?? 0)) continue;
      } catch {
        // Unreadable existing file: replace it.
      }
    }
    fs.mkdirSync(chainDir, { recursive: true });
    fs.writeFileSync(target, JSON.stringify(file.multiRunData, null, 2) + "\n");
    written.push(path.relative(broadcastDir, target));
  }

  if (written.length > 0) {
    console.log(`Materialized ${written.length} per-chain run-latest.json file(s) from multi-chain sequences.`);
    console.log("Commit them so these deployments survive later multi-chain reruns:");
    for (const file of written) {
      console.log(`  - broadcast/${file}`);
    }
  }
}

function readDeploymentsFile(deploymentsDir: string): BroadcastFile[] {
  const deploymentsFiles: BroadcastFile[] = [];

  // Get set of files tracked by git (committed or staged)
  const trackedFiles = getTrackedFiles(deploymentsDir);

  try {
    const deploymentsPath = path.join(deploymentsDir, "legacy-addresses.json");
    const resolvedPath = path.resolve(deploymentsPath);

    // Only include if file exists AND is tracked by git (committed or staged)
    if (fs.existsSync(deploymentsPath) && trackedFiles.has(resolvedPath)) {
      const data = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));

      for (const [chainId, contracts] of Object.entries(data)) {
        if (typeof contracts === "object" && contracts !== null) {
          // Create a virtual broadcast file for legacy-addresses.json
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
    console.error(`Error reading legacy-addresses.json: ${error}`);
  }

  return deploymentsFiles;
}

function extractContractAddresses(broadcastFile: BroadcastFile): Contract[] {
  if (broadcastFile.isDeploymentsJson && broadcastFile.deploymentsData) {
    // Handle legacy-addresses.json format
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
    // Handle broadcast file format (a per-chain multi-broadcast element has the same shape)
    try {
      const data = broadcastFile.multiRunData ?? JSON.parse(fs.readFileSync(broadcastFile.filePath, "utf8"));
      const contracts: Contract[] = [];
      const transactions = data.transactions || [];
      const receipts = data.receipts || [];

      // Build receipt lookups keyed by the deployed contract address. Receipts are fetched directly from the
      // node and are authoritative, whereas `transactions[].hash` is occasionally mis-associated with the wrong
      // entry by Foundry (e.g. when a sequence contains both a CREATE and a later CALL to the same address). We
      // therefore resolve a CREATE's transaction hash and block number from the receipt whose `contractAddress`
      // matches, falling back to `tx.hash` only when no matching receipt exists (e.g. simulation-only runs).
      const txHashToBlock: { [hash: string]: number } = {};
      const addressToReceipt: { [address: string]: { transactionHash: string; blockNumber: number | null } } = {};
      for (const receipt of receipts) {
        const txHash = receipt.transactionHash;
        let blockNumber = receipt.blockNumber;
        // Convert hex to decimal
        if (typeof blockNumber === "string" && blockNumber.startsWith("0x")) {
          blockNumber = parseInt(blockNumber, 16);
        }
        if (txHash && blockNumber) {
          txHashToBlock[txHash] = blockNumber;
        }
        if (receipt.contractAddress) {
          addressToReceipt[receipt.contractAddress.toLowerCase()] = { transactionHash: txHash, blockNumber };
        }
      }

      for (const tx of transactions) {
        // The beacon PROXY's CREATE only appears in the FIRST beacon run at a given salt; later runs (e.g. a
        // config upgrade) find it already deployed and skip it, so `run-latest.json` often lacks the proxy
        // CREATE. Both `upgradeToAndCall(address,bytes)` (0x4f1ef286) and `setImplementation(address)`
        // (0xd784d426) ALWAYS target the proxy and at least one of them is emitted on any beacon run that
        // changes anything, so capture the canonical `CounterfactualBeacon` address from their target.
        if (broadcastFile.scriptName === "DeployCounterfactualBeacon.s.sol" && tx.transactionType === "CALL") {
          const input: string = (tx.transaction && tx.transaction.input) || "";
          const to: string | undefined = tx.transaction && tx.transaction.to;
          if (to && (input.startsWith("0x4f1ef286") || input.startsWith("0xd784d426"))) {
            contracts.push({
              contractName: "CounterfactualBeacon",
              contractAddress: to,
              transactionHash: tx.hash,
              blockNumber: txHashToBlock[tx.hash] || null,
            });
          }
        }

        if ((tx.transactionType === "CREATE" || tx.transactionType === "CREATE2") && tx.contractAddress) {
          const receipt = addressToReceipt[tx.contractAddress.toLowerCase()];
          const txHash = receipt?.transactionHash ?? tx.hash;
          const blockNumber = receipt?.blockNumber ?? txHashToBlock[tx.hash] ?? null;

          let contractName = (tx.contractName as string | null) ?? "";

          // Special-case the CounterfactualBeacon deploy: the ERC1967Proxy is the canonical, address-
          // stable registry (every BeaconProxy embeds it). The per-chain CounterfactualBeacon
          // implementation that lives behind that proxy is not the address callers should resolve, so
          // skip it. Without this branch the generic `ERC1967Proxy → SpokePool` rewrite below would
          // misfile the beacon proxy as SpokePool, and `CounterfactualBeacon` in deployed-addresses.json
          // would point at the per-chain implementation.
          if (broadcastFile.scriptName === "DeployCounterfactualBeacon.s.sol") {
            if (contractName === "ERC1967Proxy") {
              contractName = "CounterfactualBeacon";
            } else if (contractName === "CounterfactualBeacon") {
              continue;
            }
          }

          if (contractName === "ERC1967Proxy") {
            // Resolve which contract this proxy represents by the deploying script (see comment above).
            const mappedProxyName = PROXY_LOGICAL_NAME_BY_SCRIPT[broadcastFile.scriptName];
            if (mappedProxyName) {
              contractName = mappedProxyName;
            } else if (isSpokePoolDeployScript(broadcastFile.scriptName)) {
              contractName = "SpokePool";
            } else {
              contractName = broadcastFile.scriptName.replace(/\.s\.sol$/, "").replace(/^Deploy/, "") || "UnknownProxy";
            }
          } else if (contractName.endsWith("_SpokePool")) {
            // skip the SpokePool implementation (the proxy, handled above, is the canonical address)
            continue;
          } else if (contractName === "CounterfactualBeacon" || contractName === "CounterfactualBeaconBootstrap") {
            // Skip the beacon implementation and bootstrap — neither is an address callers should resolve.
            // The canonical `CounterfactualBeacon` is the ERC1967 proxy (captured above from the
            // upgradeToAndCall/setImplementation CALL target, and via the proxy CREATE on first deploy). A
            // `CounterfactualBeacon` CREATE is always the per-chain impl behind that proxy (the proxy is an
            // `ERC1967Proxy`); it changes on every upgrade. `CounterfactualBeaconBootstrap` is the one-time
            // init shim the proxy is deployed over before being upgraded to the impl.
            continue;
          } else if (["Universal_Adapter", "OP_Adapter"].includes(contractName)) {
            // Preferred: the deploy script records the destination chain id in the broadcast `returns`
            // (see DeployUniversalAdapter.s.sol). This is unambiguous regardless of how the adapter's
            // token-bridging routes (CCTP/OFT) are configured.
            let chainId = getReturnedDestinationChainId(data);

            if (chainId === undefined) {
              // Legacy fallback for broadcasts that predate the returned chain id: infer the destination
              // by matching the adapter's CCTP domain / OFT EID constructor args against known networks.
              // nb. This is fragile (e.g. it can't resolve adapters with no CCTP/OFT route). @todo: Remove
              // once all adapters have been redeployed with the returned destination chain id.
              let cctpDomainId: string | undefined = undefined;
              let oftDstEid: string | undefined = undefined;
              switch (contractName) {
                case "Universal_Adapter":
                  cctpDomainId = tx.arguments.at(3);
                  oftDstEid = tx.arguments.at(5);
                  break;
                case "OP_Adapter":
                  cctpDomainId = tx.arguments.at(6);
                  break;
              }
              const networks = broadcastFile.chainId in TEST_NETWORKS ? TEST_NETWORKS : PRODUCTION_NETWORKS;

              // Try to find a chain id in TEST_NETWORKS/PRODUCTION_NETWORKS that matches cctpDomainId or oftDstEid
              chainId = Object.keys(networks).find((chainId) => {
                const { cctpDomain, oftEid } = networks[Number(chainId)];
                // Some chains may have properties for cctpDomainId or oftDstEid. Try to check both.
                return (
                  (cctpDomain && cctpDomain.toString() === cctpDomainId) || (oftEid && oftEid.toString() === oftDstEid)
                );
              });

              if (chainId === undefined) {
                console.log(
                  `No destination chainId for ${contractName} at ${tx.contractAddress}: broadcast returns empty ` +
                    `and no network matched cctpDomainId (${cctpDomainId}) or oftDstEid (${oftDstEid}). ` +
                    `Redeploy with a script that returns the destination chain id to fix the naming.`
                );
              }
            }

            if (chainId !== undefined) {
              contractName += `_${chainId}`;
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

function deduplicateContracts(scripts: { [scriptName: string]: Contract[] }): Map<string, Contract> {
  const contractMap = new Map<string, Contract>();
  for (const contracts of Object.values(scripts)) {
    for (const contract of contracts as Contract[]) {
      const existing = contractMap.get(contract.contractName);
      if (!existing) {
        contractMap.set(contract.contractName, contract);
      } else {
        const existingBlock = existing.blockNumber ?? 0;
        const newBlock = contract.blockNumber ?? 0;
        const hasMoreMetadata = contract.transactionHash !== "Unknown" && existing.transactionHash === "Unknown";
        if (newBlock > existingBlock || (newBlock === existingBlock && hasMoreMetadata)) {
          contractMap.set(contract.contractName, contract);
        }
      }
    }
  }
  return contractMap;
}

function generateAddressesFile(broadcastFiles: BroadcastFile[], outputFile: string): void {
  const allContracts: AllContracts = {};

  // Process each broadcast file
  for (const broadcastFile of broadcastFiles) {
    const contracts = extractContractAddresses(broadcastFile);

    if (contracts.length > 0) {
      const chainId = broadcastFile.chainId;
      const chainName = getChainName(chainId);
      // For legacy-addresses.json, use contract name as scriptName for each contract
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
        // Concatenate so a per-chain run-latest.json and a multi-broadcast entry for the same script
        // both contribute; deduplicateContracts keeps the latest deployment per contract name.
        allContracts[chainId].scripts[scriptName] = [
          ...(allContracts[chainId].scripts[scriptName] ?? []),
          ...contracts,
        ];
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

    // Collect all contracts for this chain, deduplicating by name (keep latest by block number)
    const allChainContracts = Array.from(deduplicateContracts(chainInfo.scripts).values());

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
    const contractMap = deduplicateContracts(chainInfo.scripts);

    jsonOutput.chains[chainId] = {
      chain_name: chainInfo.chainName,
      contracts: {},
    };

    for (const [contractName, contract] of contractMap) {
      jsonOutput.chains[chainId].contracts[contractName] = {
        address: toChecksumAddress(contract.contractAddress),
        ...(contract.blockNumber !== null && { block_number: contract.blockNumber }),
        ...(contract.transactionHash !== "Unknown" && { transaction_hash: contract.transactionHash }),
      };
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

  // Read legacy-addresses.json
  const deploymentsFiles = readDeploymentsFile(deploymentsDir);

  // Find all broadcast files (per-chain run-latest.json and multi-chain sequences), and persist
  // multi-chain deployments into the durable per-chain layout.
  const broadcastFiles = findBroadcastFiles(broadcastDir);
  const multiBroadcastFiles = findMultiBroadcastFiles(broadcastDir);
  materializeMultiBroadcasts(broadcastDir, multiBroadcastFiles);

  // Combine all sources (order is important, legacy-addresses.json should be first)
  const allFiles = [...deploymentsFiles, ...broadcastFiles, ...multiBroadcastFiles];

  if (allFiles.length === 0) {
    console.error("No run-latest.json files found in broadcast directory and no legacy-addresses.json found");
    process.exit(1);
  }

  console.log(
    `Found ${broadcastFiles.length} broadcast files, ${multiBroadcastFiles.length} multi-chain deployment entries, ` +
      `and ${deploymentsFiles.length} deployment entries:`
  );

  // Generate output files inside broadcast directory
  const outputFile = path.join(broadcastDir, "deployed-addresses.json");
  generateAddressesFile(allFiles, outputFile);

  console.log("\nDone!");
}

if (require.main === module) {
  main();
}
