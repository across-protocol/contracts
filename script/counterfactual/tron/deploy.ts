#!/usr/bin/env ts-node
/**
 * Shared TronWeb deployer for Tron contract deployments.
 *
 * Import from per-contract wrapper scripts:
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
import { TronWeb } from "tronweb";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40; // ~2 minutes

const TRONSCAN_URLS: Record<string, string> = {
  "728126428": "https://tronscan.org",
  "3448148188": "https://nile.tronscan.org",
};

export interface DeployResult {
  address: string; // Tron Base58 (T...)
  txID: string;
}

/** ABI-encode constructor args. Wrapper around TronWeb's ABI encoder for use by deploy scripts. */
export function encodeArgs(types: string[], values: any[]): string {
  // Lightweight TronWeb instance for ABI encoding only (no network calls).
  const tw = new TronWeb({ fullHost: "http://localhost" });
  return tw.utils.abi.encodeParams(types, values);
}

/** Convert a Tron Base58Check address (T...) to a 0x-prefixed 20-byte EVM hex address. */
export function tronToEvmAddress(base58: string): string {
  const hex = TronWeb.address.toHex(base58);
  // TronWeb returns 41-prefixed hex (e.g. "41abc..."). Strip the 41 prefix to get the 20-byte address.
  // Guard against alternate formats: if it starts with "0x41", strip 4 chars; if "41", strip 2.
  if (hex.startsWith("0x41") && hex.length === 44) return "0x" + hex.slice(4);
  if (hex.startsWith("41") && hex.length === 42) return "0x" + hex.slice(2);
  throw new Error(`Unexpected TronWeb hex address format: ${hex}`);
}

/** Decode ABI-encoded constructor args into human-readable strings for the broadcast `arguments` field. */
function decodeConstructorArgs(tronWeb: TronWeb, abi: any[], parameterHex: string): string[] | null {
  const ctor = abi.find((e: any) => e.type === "constructor");
  if (!ctor || !ctor.inputs?.length || !parameterHex) return null;
  try {
    const types = ctor.inputs.map((i: any) => i.type);
    const names = ctor.inputs.map((i: any) => i.name);
    const decoded = tronWeb.utils.abi.decodeParams(names, types, "0x" + parameterHex, false);
    return ctor.inputs.map((input: any) => {
      const val = decoded[input.name];
      // TronWeb returns addresses as 41-prefixed hex; convert to Base58Check (T...) for TronScan.
      if (input.type === "address" && typeof val === "string" && val.startsWith("41") && val.length === 42) {
        return tronWeb.address.fromHex(val);
      }
      return val.toString();
    });
  } catch {
    return null;
  }
}

/** Write a Foundry-compatible broadcast artifact to broadcast/<ContractName>/<chainId>/. */
function writeBroadcastArtifact(opts: {
  tronWeb: TronWeb;
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
  const txHash = opts.txID;
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
        arguments: decodeConstructorArgs(opts.tronWeb, opts.abi, opts.parameter || ""),
        transaction: {
          from: opts.deployerAddress,
          gas: "0x" + opts.feeLimit.toString(16),
          value: "0x0",
          input: initcode,
          chainId: "0x" + chainIdNum.toString(16),
        },
        additionalContracts: [],
      },
    ],
    receipts: [
      {
        status: "0x1",
        cumulativeGasUsed: gasUsed,
        transactionHash: txHash,
        blockHash: null, // TRON doesn't expose blockHash via getTransactionInfo
        blockNumber: blockNum,
        gasUsed,
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

  const TRON_CHAIN_IDS = ["728126428", "3448148188"]; // mainnet, Nile testnet
  if (!TRON_CHAIN_IDS.includes(chainId)) {
    console.log(`Error: invalid chain ID "${chainId}". Use 728126428 (Tron mainnet) or 3448148188 (Nile testnet).`);
    process.exit(1);
  }

  const mnemonic = process.env.MNEMONIC;
  const fullNode = process.env[`NODE_URL_${chainId}`];
  if (!mnemonic) {
    console.log("Error: MNEMONIC env var is required.");
    process.exit(1);
  }
  if (!fullNode) {
    console.log(`Error: NODE_URL_${chainId} env var is required (Tron full node URL).`);
    process.exit(1);
  }

  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "1500000000", 10);

  // Create a TronWeb instance (private key set below after mnemonic derivation).
  const tronWeb = new TronWeb({ fullHost: fullNode });

  // Derive account 0 private key from mnemonic (same derivation as Foundry's vm.deriveKey(mnemonic, 0)).
  // We use Ethereum's HD path (m/44'/60'/0'/0/0) — NOT Tron's default (m/44'/195'/0'/0/0) — because
  // the deployer key must match the one Foundry derives. TronWeb.fromMnemonic() enforces Tron's path,
  // so we use the bundled ethers HDNodeWallet directly to derive with the Ethereum path.
  const { ethersHDNodeWallet, Mnemonic } = tronWeb.utils.ethersUtils;
  const mnemonicObj = Mnemonic.fromPhrase(mnemonic);
  const wallet = ethersHDNodeWallet.fromMnemonic(mnemonicObj, "m/44'/60'/0'/0/0");
  const privateKey = wallet.privateKey.slice(2);
  tronWeb.setPrivateKey(privateKey);
  const deployerAddressRaw = tronWeb.address.fromPrivateKey(privateKey);
  if (typeof deployerAddressRaw !== "string") {
    console.log("Error: could not derive deployer address from private key.");
    process.exit(1);
  }
  const deployerAddress = deployerAddressRaw;

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

  if (!result.result) {
    console.log("Error: transaction rejected:", JSON.stringify(result, null, 2));
    process.exit(1);
  }

  const txID: string = result.transaction?.txID;
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

  // Extract contract address from transaction info (Tron returns hex with 41 prefix).
  const tronHexAddress: string = txInfo.contract_address;
  if (!tronHexAddress) {
    console.log("Error: no contract_address in transaction info.");
    process.exit(1);
  }

  const contractAddress = tronWeb.address.fromHex(tronHexAddress);
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  console.log(`\nContract deployed!`);
  console.log(`  Address:  ${contractAddress}`);
  console.log(`  TX ID:    ${txID}`);
  console.log(`  Tronscan: ${tronscanBase}/#/contract/${contractAddress}`);

  writeBroadcastArtifact({
    tronWeb,
    contractName,
    contractAddress,
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
    address: contractAddress,
    txID,
  };
}
