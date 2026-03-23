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
 *   USP_HUB_POOL_STORE_ADDRESS        — HubPoolStore contract address (Tron Base58Check, T...)
 *   USP_WRAPPED_NATIVE_TOKEN_ADDRESS  — Wrapped native token (WTRX) address (Tron Base58Check, T...)
 *   USP_DEPOSIT_QUOTE_TIME_BUFFER     — Deposit quote time buffer in seconds
 *   USP_FILL_DEADLINE_BUFFER          — Fill deadline buffer in seconds
 *   USP_L2_USDC_ADDRESS               — USDC token address on Tron (Tron Base58Check, T...)
 *   USP_CCTP_TOKEN_MESSENGER_ADDRESS  — CCTP TokenMessenger address (Tron Base58Check, T...), or zero address to disable
 *   USP_OFT_DST_EID                   — LayerZero OFT destination endpoint ID (0 to disable)
 *   USP_OFT_FEE_CAP                   — LayerZero OFT fee cap in wei (0 to disable)
 *
 * Usage:
 *   yarn tron-deploy-universal-spokepool <chain-id>
 */

import "dotenv/config";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress } from "./deploy";

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
  const hubPoolStoreAddress = tronToEvmAddress(requireEnv("USP_HUB_POOL_STORE_ADDRESS"));
  const wrappedNativeToken = tronToEvmAddress(requireEnv("USP_WRAPPED_NATIVE_TOKEN_ADDRESS"));
  const depositQuoteTimeBuffer = requireEnv("USP_DEPOSIT_QUOTE_TIME_BUFFER");
  const fillDeadlineBuffer = requireEnv("USP_FILL_DEADLINE_BUFFER");
  const l2Usdc = tronToEvmAddress(requireEnv("USP_L2_USDC_ADDRESS"));
  const cctpTokenMessenger = tronToEvmAddress(requireEnv("USP_CCTP_TOKEN_MESSENGER_ADDRESS"));
  const oftDstEid = requireEnv("USP_OFT_DST_EID");
  const oftFeeCap = requireEnv("USP_OFT_FEE_CAP");

  console.log(`  Admin update buffer:  ${adminUpdateBuffer}s`);
  console.log(`  Helios:               ${heliosAddress}`);
  console.log(`  HubPoolStore:         ${hubPoolStoreAddress}`);
  console.log(`  Wrapped native token: ${wrappedNativeToken}`);
  console.log(`  Deposit quote buffer: ${depositQuoteTimeBuffer}s`);
  console.log(`  Fill deadline buffer: ${fillDeadlineBuffer}s`);
  console.log(`  L2 USDC:              ${l2Usdc}`);
  console.log(`  CCTP TokenMessenger:  ${cctpTokenMessenger}`);
  console.log(`  OFT dst EID:          ${oftDstEid}`);
  console.log(`  OFT fee cap:          ${oftFeeCap}`);

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
