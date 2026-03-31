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
 *   USP_ADMIN_UPDATE_BUFFER           — Admin update buffer in seconds (e.g. 86400 = 24h)
 *   USP_HELIOS_ADDRESS                — SP1Helios contract address (Tron Base58Check, T...)
 *   USP_WRAPPED_NATIVE_TOKEN_ADDRESS  — Wrapped native token (WTRX) address (Tron Base58Check, T...)
 *   USP_DEPOSIT_QUOTE_TIME_BUFFER     — Deposit quote time buffer in seconds
 *   USP_FILL_DEADLINE_BUFFER          — Fill deadline buffer in seconds
 *
 * Usage:
 *   yarn tron-deploy-universal-spokepool <chain-id>
 */

import "dotenv/config";
import * as path from "path";
import { CHAIN_IDs } from "../../../utils";
import { L1_ADDRESS_MAP } from "../../../src/consts";
import { deployContract, encodeArgs, tronToEvmAddress } from "./deploy";

const TRON_TESTNET_CHAIN_IDS = ["3448148188"];

function getHubPoolStoreAddress(spokeChainId: string): string {
  const hubChainId = TRON_TESTNET_CHAIN_IDS.includes(spokeChainId) ? CHAIN_IDs.SEPOLIA : CHAIN_IDs.MAINNET;
  const address = L1_ADDRESS_MAP[hubChainId]?.hubPoolStore;
  if (!address) {
    console.log(`Error: hubPoolStore not found in L1_ADDRESS_MAP for hub chain ${hubChainId}`);
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
  const chainId = process.argv[2];
  if (!chainId) {
    console.log("Usage: yarn tron-deploy-universal-spokepool <chain-id>");
    process.exit(1);
  }

  console.log("=== Universal_SpokePool Tron Deployment ===");
  console.log(`Chain ID: ${chainId}`);

  const adminUpdateBuffer = requireEnv("USP_ADMIN_UPDATE_BUFFER");
  const heliosAddress = tronToEvmAddress(requireEnv("USP_HELIOS_ADDRESS"));
  const hubPoolStoreAddress = getHubPoolStoreAddress(chainId);
  const wrappedNativeToken = tronToEvmAddress(requireEnv("USP_WRAPPED_NATIVE_TOKEN_ADDRESS"));
  const depositQuoteTimeBuffer = requireEnv("USP_DEPOSIT_QUOTE_TIME_BUFFER");
  const fillDeadlineBuffer = requireEnv("USP_FILL_DEADLINE_BUFFER");
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
