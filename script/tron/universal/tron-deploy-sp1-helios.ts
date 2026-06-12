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
import * as childProcess from "child_process";
import * as url from "url";
import { createHash } from "crypto";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId } from "../deploy";
import { TronWeb as TronWebImport } from "tronweb";

const GITHUB_RELEASE_URL = "https://github.com/across-protocol/sp1-helios/releases";
const SCRIPT_DIR = path.resolve(__dirname);

function downloadBinary(binaryPath: string, downloadUrl: string): void {
  const curlCommand = [
    "curl",
    "-L",
    "-o",
    binaryPath,
    "--fail",
    downloadUrl,
  ];

  const escapedCommand = curlCommand.map((arg) => {
    if (arg.includes(" ")) {
      return `"${arg}"`;
    }
    return arg;
  }).join(" ");

  childProcess.execSync(escapedCommand, { stdio: "inherit" });
}

// Rest of the code remains the same