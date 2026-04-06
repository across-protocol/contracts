#!/usr/bin/env ts-node
/**
 * Deploys SP1Helios to Tron via TronWeb.
 *
 * Steps:
 *   1. Download the genesis binary from GitHub releases (platform-aware)
 *   2. Verify the binary's SHA-256 checksum against checksums.json
 *   3. Run the genesis binary to generate/update genesis.json
 *   4. Read genesis.json and ABI-encode the SP1Helios constructor args
 *   5. Deploy SP1Helios to Tron
 *
 * Env vars:
 *   MNEMONIC                     — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428           — Tron mainnet full node URL
 *   NODE_URL_3448148188          — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT               — optional, in sun (default: 100000000 = 100 TRX)
 *   SP1_RELEASE_TRON             — Genesis binary version (e.g. "0.1.0-alpha.20")
 *   SP1_PROVER_MODE_TRON         — SP1 prover type: "mock", "cpu", "cuda", or "network"
 *   SP1_VERIFIER_ADDRESS_TRON    — SP1 verifier contract address (Tron Base58Check, T...)
 *   SP1_STATE_UPDATERS_TRON      — Comma-separated list of state updater addresses (Tron Base58Check)
 *   SP1_VKEY_UPDATER_TRON        — VKey updater address (Tron Base58Check, T...)
 *   SP1_CONSENSUS_RPCS_LIST_TRON — Comma-separated list of consensus RPC URLs
 *
 * Options:
 *   --testnet          — deploy to Tron Nile testnet (default: mainnet)
 *   --fee-limit <sun>  — fee limit in sun (default: 100000000 = 100 TRX)
 *
 * Usage:
 *   yarn tron-deploy-sp1-helios [--testnet] [--fee-limit <sun>]
 */

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { execSync } from "child_process";
import { createHash } from "crypto";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId } from "../deploy";
import { TronWeb as TronWebImport } from "tronweb";

const GITHUB_RELEASE_URL = "https://github.com/across-protocol/sp1-helios/releases";
const SCRIPT_DIR = path.resolve(__dirname);

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.log(`Error: ${name} env var is required.`);
    process.exit(1);
  }
  return value;
}

/** Detect platform and return the binary suffix. */
function detectPlatform(): string {
  const platform = os.platform();
  if (platform === "darwin") {
    console.log("Detected platform: macOS (arm64_darwin)");
    return "arm64_darwin";
  } else {
    console.log("Detected platform: Linux (amd64_linux)");
    return "amd64_linux";
  }
}

/** Download the genesis binary from GitHub releases. */
function downloadGenesisBinary(version: string): string {
  const platformSuffix = detectPlatform();
  const binaryName = `genesis_${version}_${platformSuffix}`;
  const downloadUrl = `${GITHUB_RELEASE_URL}/download/v${version}/${binaryName}`;
  const binaryPath = path.join(SCRIPT_DIR, "genesis-binary");

  console.log(`Binary name: ${binaryName}`);
  console.log(`Download URL: ${downloadUrl}`);
  console.log("Downloading genesis binary...");

  execSync(`curl -L -o "${binaryPath}" --fail "${downloadUrl}"`, { stdio: "inherit" });
  console.log("Download complete");

  verifyBinaryChecksum(binaryName, binaryPath);
  fs.chmodSync(binaryPath, 0o755);

  return binaryPath;
}

/** Verify the downloaded binary's SHA-256 checksum against checksums.json. */
function verifyBinaryChecksum(binaryName: string, binaryPath: string): void {
  console.log("Verifying binary checksum...");

  const checksumsPath = path.resolve(SCRIPT_DIR, "../../universal/checksums.json");
  const checksums: Record<string, string> = JSON.parse(fs.readFileSync(checksumsPath, "utf-8"));

  const expectedChecksum = checksums[binaryName];
  if (!expectedChecksum) {
    console.log(`Error: no checksum found for binary: ${binaryName}`);
    console.log("Please add the checksum to script/universal/checksums.json");
    process.exit(1);
  }
  console.log(`Expected checksum: ${expectedChecksum}`);

  const fileBuffer = fs.readFileSync(binaryPath);
  const actualChecksum = createHash("sha256").update(fileBuffer).digest("hex");
  console.log(`Actual checksum:   ${actualChecksum}`);

  if (expectedChecksum !== actualChecksum) {
    console.log("Error: checksum mismatch! Possible tampering detected.");
    process.exit(1);
  }
  console.log("Checksum verified successfully");
}

/** Run the genesis binary to generate/update genesis.json. */
function runGenesisBinary(binaryPath: string, sp1Prover: string, privateKeyHex: string): void {
  const sp1VerifierAddress = requireEnv("SP1_VERIFIER_ADDRESS_TRON");
  const stateUpdaters = requireEnv("SP1_STATE_UPDATERS_TRON");
  const vkeyUpdater = requireEnv("SP1_VKEY_UPDATER_TRON");
  const consensusRpcsList = requireEnv("SP1_CONSENSUS_RPCS_LIST_TRON");

  console.log(`SP1_VERIFIER_ADDRESS: ${sp1VerifierAddress}`);
  console.log(`STATE_UPDATERS: ${stateUpdaters}`);
  console.log(`VKEY_UPDATER: ${vkeyUpdater}`);
  console.log(`CONSENSUS_RPCS_LIST: ${consensusRpcsList}`);

  // The genesis binary expects EVM-format (0x) addresses. Convert Tron Base58Check addresses.
  const verifierEvm = tronToEvmAddress(sp1VerifierAddress);
  const vkeyUpdaterEvm = tronToEvmAddress(vkeyUpdater);
  const updatersEvm = stateUpdaters
    .split(",")
    .map((a) => tronToEvmAddress(a.trim()))
    .join(",");

  console.log("Running genesis binary...");
  execSync(`"${binaryPath}" --out "${SCRIPT_DIR}"`, {
    stdio: "inherit",
    env: {
      ...process.env,
      SOURCE_CHAIN_ID: "1",
      SP1_PROVER: sp1Prover,
      PRIVATE_KEY: privateKeyHex,
      SP1_VERIFIER_ADDRESS: verifierEvm,
      UPDATERS: updatersEvm,
      VKEY_UPDATER: vkeyUpdaterEvm,
      CONSENSUS_RPCS_LIST: consensusRpcsList,
    },
  });
  console.log("Genesis config updated successfully");
}

/** Read genesis.json and return ABI-encoded constructor args for SP1Helios. */
function readGenesisAndEncode(): string {
  const genesisPath = path.join(SCRIPT_DIR, "genesis.json");
  if (!fs.existsSync(genesisPath)) {
    console.log(`Error: genesis.json not found at ${genesisPath}`);
    process.exit(1);
  }

  const genesis = JSON.parse(fs.readFileSync(genesisPath, "utf-8"));
  console.log("\n=== Genesis Config ===");
  console.log(`  executionStateRoot: ${genesis.executionStateRoot}`);
  console.log(`  genesisTime:        ${genesis.genesisTime}`);
  console.log(`  head:               ${genesis.head}`);
  console.log(`  header:             ${genesis.header}`);
  console.log(`  heliosProgramVkey:  ${genesis.heliosProgramVkey}`);
  console.log(`  secondsPerSlot:     ${genesis.secondsPerSlot}`);
  console.log(`  slotsPerEpoch:      ${genesis.slotsPerEpoch}`);
  console.log(`  slotsPerPeriod:     ${genesis.slotsPerPeriod}`);
  console.log(`  syncCommitteeHash:  ${genesis.syncCommitteeHash}`);
  console.log(`  verifier:           ${genesis.verifier}`);
  console.log(`  vkeyUpdater:        ${genesis.vkeyUpdater}`);
  console.log(`  updaters:           ${JSON.stringify(genesis.updaters)}`);

  // The SP1Helios constructor takes a single InitParams struct as a tuple.
  return encodeArgs(
    ["(bytes32,uint256,uint256,bytes32,bytes32,uint256,uint256,uint256,bytes32,address,address,address[])"],
    [
      [
        genesis.executionStateRoot,
        genesis.genesisTime,
        genesis.head,
        genesis.header,
        genesis.heliosProgramVkey,
        genesis.secondsPerSlot,
        genesis.slotsPerEpoch,
        genesis.slotsPerPeriod,
        genesis.syncCommitteeHash,
        genesis.verifier,
        genesis.vkeyUpdater,
        genesis.updaters,
      ],
    ]
  );
}

function parseFlag(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 && idx + 1 < process.argv.length ? process.argv[idx + 1] : undefined;
}

async function main(): Promise<void> {
  const chainId = resolveChainId();

  const feeLimitRaw = parseFlag("--fee-limit");
  const feeLimit = feeLimitRaw ? parseInt(feeLimitRaw, 10) : undefined;

  const version = requireEnv("SP1_RELEASE_TRON");
  const sp1Prover = requireEnv("SP1_PROVER_MODE_TRON");
  const mnemonic = requireEnv("MNEMONIC");

  console.log("=== SP1Helios Tron Deployment ===");
  console.log(`Version:    ${version}`);
  console.log(`SP1 Prover: ${sp1Prover}`);
  console.log(`Chain ID:   ${chainId}`);

  // Derive private key (Ethereum HD path to match Foundry) for the genesis binary.
  const tw = new TronWebImport({ fullHost: "http://localhost" });
  const { ethersHDNodeWallet, Mnemonic } = tw.utils.ethersUtils;
  const mnemonicObj = Mnemonic.fromPhrase(mnemonic);
  const wallet = ethersHDNodeWallet.fromMnemonic(mnemonicObj, "m/44'/60'/0'/0/0");
  const privateKeyHex = wallet.privateKey; // 0x-prefixed

  // Step 1-2: Download and verify genesis binary
  const binaryPath = downloadGenesisBinary(version);

  // Step 3: Run genesis binary to generate genesis.json
  runGenesisBinary(binaryPath, sp1Prover, privateKeyHex);

  // Step 4: Read genesis.json and encode constructor args
  const encodedArgs = readGenesisAndEncode();

  // Step 5: Deploy SP1Helios
  console.log("\n=== WARNING ===");
  console.log("Once SP1Helios is deployed, you have 7 days to deploy the UniversalSpokePool");
  console.log("and activate it in-protocol. After 7 days with no update, the contract becomes");
  console.log("immutable and cannot be updated.");
  console.log("================\n");

  const artifactPath = path.resolve(__dirname, "../../../out-tron/SP1Helios.sol/SP1Helios.json");

  await deployContract({ chainId, artifactPath, encodedArgs, feeLimit });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
