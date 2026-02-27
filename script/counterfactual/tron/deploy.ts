#!/usr/bin/env ts-node
/**
 * Shared TronWeb deployer for Tron contract deployments.
 *
 * Can be used standalone:
 *   npx ts-node deploy.ts <chain-id> <artifact-json-path> [abi-encoded-constructor-args-hex]
 *
 * Or imported by per-contract wrapper scripts:
 *   import { deployContract } from "./deploy";
 *   await deployContract({ chainId, artifactPath, encodedArgs });
 *
 * Env vars:
 *   MNEMONIC              — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428    — Tron mainnet full node URL
 *   NODE_URL_3448148188   — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT        — optional, in sun (default: 1500000000 = 1500 TRX)
 */

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import { execSync } from "child_process";
import { Wallet, utils } from "ethers";
import { TronWeb } from "tronweb";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40; // ~2 minutes

const TRONSCAN_URLS: Record<string, string> = {
  "728126428": "https://tronscan.org",
  "3448148188": "https://nile.tronscan.org",
};

export interface DeployResult {
  evmAddress: string;
  tronAddress: string;
  txID: string;
}

/** Decode ABI-encoded constructor args into human-readable strings for the broadcast `arguments` field. */
function decodeConstructorArgs(abi: any[], parameterHex: string): string[] | null {
  const ctor = abi.find((e: any) => e.type === "constructor");
  if (!ctor || !ctor.inputs?.length || !parameterHex) return null;
  try {
    const types = ctor.inputs.map((i: any) => i.type);
    const decoded = utils.defaultAbiCoder.decode(types, "0x" + parameterHex);
    return ctor.inputs.map((input: any, i: number) => {
      const val = decoded[i];
      if (input.type === "address") return utils.getAddress(val);
      return val.toString();
    });
  } catch {
    return null;
  }
}

function getGitCommit(): string {
  try {
    return execSync("git rev-parse --short HEAD", { encoding: "utf-8" }).trim();
  } catch {
    return "";
  }
}

/** Write a Foundry-compatible broadcast artifact to broadcast/<ContractName>/<chainId>/. */
function writeBroadcastArtifact(opts: {
  contractName: string;
  contractAddress: string;
  txID: string;
  chainId: string;
  deployerAddress: string;
  bytecode: string;
  parameter: string | undefined;
  abi: any[];
  feeLimit: number;
  txInfo: any;
}): void {
  // Use TronDeploy<ContractName>.s.sol as the directory name for consistency with existing broadcast artifacts.
  const scriptName = `TronDeploy${opts.contractName}.s.sol`;
  const chainIdNum = parseInt(opts.chainId, 10);
  const now = Date.now();
  const txHash = `0x${opts.txID}`;
  const initcode = `0x${opts.bytecode}${opts.parameter || ""}`;
  const blockNum = opts.txInfo.blockNumber ? "0x" + opts.txInfo.blockNumber.toString(16) : "0x0";
  const energyUsed = opts.txInfo.receipt?.energy_usage_total;
  const gasUsed = energyUsed ? "0x" + energyUsed.toString(16) : "0x0";

  const broadcast = {
    transactions: [
      {
        hash: txHash,
        transactionType: "CREATE",
        contractName: opts.contractName,
        contractAddress: opts.contractAddress,
        function: null,
        arguments: decodeConstructorArgs(opts.abi, opts.parameter || ""),
        transaction: {
          from: opts.deployerAddress,
          gas: "0x" + opts.feeLimit.toString(16),
          value: "0x0",
          input: initcode,
          nonce: "0x0",
          chainId: "0x" + chainIdNum.toString(16),
        },
        additionalContracts: [],
        isFixedGasLimit: false,
      },
    ],
    receipts: [
      {
        status: "0x1",
        cumulativeGasUsed: gasUsed,
        logs: [],
        logsBloom: "0x" + "00".repeat(256),
        type: "0x0",
        transactionHash: txHash,
        transactionIndex: "0x0",
        blockHash: txHash, // TRON doesn't expose blockHash via getTransactionInfo
        blockNumber: blockNum,
        gasUsed,
        effectiveGasPrice: "0x0",
        from: opts.deployerAddress,
        to: null,
        contractAddress: opts.contractAddress,
      },
    ],
    libraries: [],
    pending: [],
    returns: {},
    timestamp: now,
    chain: chainIdNum,
    commit: getGitCommit(),
  };

  const broadcastDir = path.resolve(__dirname, "../../../broadcast", scriptName, opts.chainId);
  fs.mkdirSync(broadcastDir, { recursive: true });

  const json = JSON.stringify(broadcast, null, 2) + "\n";
  const runFile = path.join(broadcastDir, `run-${now}.json`);
  const latestFile = path.join(broadcastDir, "run-latest.json");

  fs.writeFileSync(runFile, json);
  fs.writeFileSync(latestFile, json);
  console.log(`  Broadcast:    ${runFile}`);
}

/**
 * Deploy a contract to Tron via TronWeb.
 *
 * @param opts.chainId       Tron chain ID (728126428 for mainnet, 3448148188 for Nile testnet)
 * @param opts.artifactPath  Path to the Foundry-compiled artifact JSON
 * @param opts.encodedArgs   Optional ABI-encoded constructor args (0x-prefixed hex)
 * @returns Deployed contract addresses and transaction ID
 */
export async function deployContract(opts: {
  chainId: string;
  artifactPath: string;
  encodedArgs?: string;
}): Promise<DeployResult> {
  const { chainId, artifactPath, encodedArgs } = opts;

  const mnemonic = process.env.MNEMONIC;
  const fullNode = process.env[`NODE_URL_${chainId}`];
  if (!mnemonic) {
    console.log("Error: MNEMONIC env var is required.");
    process.exit(1);
  }
  if (!fullNode) {
    console.log(`Error: NODE_URL_${chainId} env var is required.`);
    process.exit(1);
  }

  // Derive account 0 private key from mnemonic (same derivation as Foundry's vm.deriveKey(mnemonic, 0)).
  // TronWeb expects a raw hex key without the 0x prefix.
  const wallet = Wallet.fromMnemonic(mnemonic);
  const privateKey = wallet.privateKey.slice(2);
  const deployerAddress = wallet.address.toLowerCase();

  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "1500000000", 10);

  // Read the Foundry-compiled artifact to get the ABI and bytecode.
  if (!fs.existsSync(artifactPath)) {
    console.log(`Error: artifact not found at ${artifactPath}. Run "FOUNDRY_PROFILE=tron forge build" first.`);
    process.exit(1);
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const abi = artifact.abi;
  let bytecode: string = artifact.bytecode?.object || artifact.bytecode;
  if (typeof bytecode === "string" && bytecode.startsWith("0x")) {
    bytecode = bytecode.slice(2);
  }
  if (!abi || !bytecode) {
    console.log("Error: artifact missing abi or bytecode.");
    process.exit(1);
  }

  // Extract contract name from artifact filename (e.g. "CounterfactualDepositCCTP" from ".../CounterfactualDepositCCTP.json").
  const contractName = path.basename(artifactPath, ".json");

  // Strip 0x prefix from encoded args if provided (TronWeb expects raw hex).
  let parameter: string | undefined;
  if (encodedArgs) {
    parameter = encodedArgs.startsWith("0x") ? encodedArgs.slice(2) : encodedArgs;
  }

  const tronWeb = new TronWeb({ fullHost: fullNode, privateKey });

  console.log(`Deploying ${contractName} to ${fullNode}...`);
  if (parameter) console.log(`  Constructor args: 0x${parameter}`);
  console.log(`  Fee limit: ${feeLimit} sun (${feeLimit / 1e6} TRX)`);

  // Build the CreateSmartContract transaction via TronWeb.
  const txOptions = {
    abi,
    bytecode,
    name: contractName,
    feeLimit,
    ...(parameter ? { parameters: [] as unknown[], rawParameter: parameter } : {}),
  };

  const tx = await tronWeb.transactionBuilder.createSmartContract(txOptions);

  // Sign the transaction (SHA-256 + secp256k1, not keccak256 like Ethereum).
  const signedTx = await tronWeb.trx.sign(tx);

  // Broadcast the signed transaction to the Tron network.
  const result = await tronWeb.trx.sendRawTransaction(signedTx);

  if (!(result as any).result) {
    console.log("Error: transaction rejected:", JSON.stringify(result, null, 2));
    process.exit(1);
  }

  const txID: string = (result as any).txid || (result as any).transaction?.txID;
  console.log(`Transaction sent: ${txID}`);

  // Poll for confirmation — Tron doesn't return receipts synchronously.
  let txInfo: any;
  for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    txInfo = await tronWeb.trx.getTransactionInfo(txID);
    if (txInfo && txInfo.id) break;
    console.log(`Waiting for confirmation... (${i + 1}/${MAX_POLL_ATTEMPTS})`);
  }

  if (!txInfo || !txInfo.id) {
    console.log("Error: transaction not confirmed within timeout.");
    process.exit(1);
  }

  if (txInfo.receipt?.result !== "SUCCESS") {
    console.log("Error: transaction failed:", JSON.stringify(txInfo, null, 2));
    process.exit(1);
  }

  // Extract contract address from transaction info.
  // Tron returns addresses in hex format with a 41 prefix (instead of 0x).
  const tronHexAddress: string = txInfo.contract_address;
  if (!tronHexAddress) {
    console.log("Error: no contract_address in transaction info.");
    process.exit(1);
  }

  // Convert Tron hex address (41...) to standard 20-byte EVM hex.
  let evmAddress = tronHexAddress;
  if (evmAddress.startsWith("41") && evmAddress.length === 42) {
    evmAddress = evmAddress.slice(2);
  }

  // Convert to Base58Check for display (Tron's user-facing format, T... prefix).
  const base58Address = tronWeb.address.fromHex(tronHexAddress);

  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  console.log(`\nContract deployed!`);
  console.log(`  EVM address:  0x${evmAddress}`);
  console.log(`  Tron address: ${base58Address}`);
  console.log(`  TX ID:        ${txID}`);
  console.log(`  Tronscan:     ${tronscanBase}/#/contract/${base58Address}`);

  // Write deployment artifact to deployments/tron/<ContractName>.json.
  const deploymentsDir = path.resolve(__dirname, "../../../deployments/tron");
  fs.mkdirSync(deploymentsDir, { recursive: true });
  const artifactFile = path.join(deploymentsDir, `${contractName}.json`);

  const deployment = {
    contractName,
    address: `0x${evmAddress}`,
    tronAddress: base58Address,
    transactionHash: txID,
    constructorArgs: encodedArgs || null,
    abi,
    deployedAt: new Date().toISOString(),
    network: fullNode,
    solcVersion: "0.8.25",
  };

  fs.writeFileSync(artifactFile, JSON.stringify(deployment, null, 2) + "\n");
  console.log(`  Artifact:     ${artifactFile}`);

  // Write Foundry-compatible broadcast artifact to broadcast/.
  writeBroadcastArtifact({
    contractName,
    contractAddress: `0x${evmAddress}`,
    txID,
    chainId,
    deployerAddress,
    bytecode,
    parameter,
    abi,
    feeLimit,
    txInfo,
  });

  return {
    evmAddress: `0x${evmAddress}`,
    tronAddress: base58Address,
    txID,
  };
}

// Run standalone when executed directly (not imported as a module).
if (require.main === module) {
  const chainId = process.argv[2];
  const artifactPath = process.argv[3];
  const encodedArgs = process.argv[4];

  if (!chainId || !artifactPath) {
    console.log("Usage: npx ts-node deploy.ts <chain-id> <artifact-json-path> [abi-encoded-constructor-args-hex]");
    process.exit(1);
  }

  deployContract({ chainId, artifactPath, encodedArgs }).catch((err) => {
    console.log("Fatal error:", err.message || err);
    process.exit(1);
  });
}
