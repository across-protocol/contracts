#!/usr/bin/env ts-node
/**
 * Deploys Universal_SpokePool to Tron via TronWeb.
 *
 * This deploys the implementation contract only — it must be wrapped in a UUPS proxy
 * and initialized separately.
 *
 * Env vars:
 *   MNEMONIC                          — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428                — Tron mainnet full node URL
 *   NODE_URL_3448148188               — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT                    — optional, in sun (default: 1500000000 = 1500 TRX)
 *   USP_HELIOS_ADDRESS                — SP1Helios contract address (Tron Base58Check, T...)
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-universal-spokepool [--testnet]
 */

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId, TRON_TESTNET_CHAIN_ID } from "./deploy";

// WTRX (Wrapped TRX) contract address
const WTRX_ADDRESS = "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR";

/** Read and cache generated/constants.json. */
function readConstants(): any {
  const constantsPath = path.resolve(__dirname, "../../../generated/constants.json");
  return JSON.parse(fs.readFileSync(constantsPath, "utf-8"));
}

/** Read the HubPoolStore address from generated/constants.json, matching the Solidity deploy script logic. */
function getHubPoolStoreAddress(constants: any, spokeChainId: string): string {
  const hubChainId = spokeChainId === TRON_TESTNET_CHAIN_ID ? "11155111" : "1";
  const address = constants.L1_ADDRESS_MAP?.[hubChainId]?.hubPoolStore;
  if (!address) {
    console.log(`Error: hubPoolStore not found in constants.json for hub chain ${hubChainId}`);
    process.exit(1);
  }
  return address;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.log(`Error: ${name} env var is required.`);
    process.exit(1);
  }
  return value;
}

async function main(): Promise<void> {
  const chainId = resolveChainId();

  console.log("=== Universal_SpokePool Tron Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const constants = readConstants();

  const adminUpdateBuffer = 86400; // 1 day, matching DeployUniversalSpokePool.s.sol
  const heliosAddress = tronToEvmAddress(requireEnv("USP_HELIOS_ADDRESS"));
  const hubPoolStoreAddress = getHubPoolStoreAddress(constants, chainId);
  const wrappedNativeToken = tronToEvmAddress(WTRX_ADDRESS);
  const depositQuoteTimeBuffer = constants.TIME_CONSTANTS.QUOTE_TIME_BUFFER;
  const fillDeadlineBuffer = constants.TIME_CONSTANTS.FILL_DEADLINE_BUFFER;
  // USDC / CCTP is not supported on Tron.
  const l2Usdc = "0x0000000000000000000000000000000000000000";
  const cctpTokenMessenger = "0x0000000000000000000000000000000000000000";
  // OFT is not supported on Tron.
  const oftDstEid = "0";
  const oftFeeCap = "0";

  console.log(`  Admin update buffer:  ${adminUpdateBuffer}s`);
  console.log(`  Helios:               ${heliosAddress}`);
  console.log(`  HubPoolStore:         ${hubPoolStoreAddress}`);
  console.log(`  Wrapped native token: ${wrappedNativeToken}`);
  console.log(`  Deposit quote buffer: ${depositQuoteTimeBuffer}s`);
  console.log(`  Fill deadline buffer: ${fillDeadlineBuffer}s`);
  console.log(`  L2 USDC:              ${l2Usdc} (disabled — CCTP not supported on Tron)`);
  console.log(`  CCTP TokenMessenger:  ${cctpTokenMessenger} (disabled)`);
  console.log(`  OFT dst EID:          ${oftDstEid} (disabled — OFT not supported on Tron)`);
  console.log(`  OFT fee cap:          ${oftFeeCap} (disabled)`);

  // Constructor: (uint256, address, address, address, uint32, uint32, IERC20, ITokenMessenger, uint32, uint256)
  const encodedArgs = encodeArgs(
    ["uint256", "address", "address", "address", "uint32", "uint32", "address", "address", "uint32", "uint256"],
    [
      adminUpdateBuffer,
      heliosAddress,
      hubPoolStoreAddress,
      wrappedNativeToken,
      depositQuoteTimeBuffer,
      fillDeadlineBuffer,
      l2Usdc,
      cctpTokenMessenger,
      oftDstEid,
      oftFeeCap,
    ]
  );

  const artifactPath = path.resolve(__dirname, "../../../out-tron/Universal_SpokePool.sol/Universal_SpokePool.json");

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
