#!/usr/bin/env ts-node
/**
 * Deploys Universal_SpokePool to Tron via TronWeb.
 *
 * Deploys the implementation contract and wraps it in a UUPS ERC1967Proxy,
 * matching the behavior of DeployUniversalSpokePool.s.sol.
 *
 * Env vars:
 *   MNEMONIC                          — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428                — Tron mainnet full node URL
 *   NODE_URL_3448148188               — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT                    — optional, in sun (default: 100000000 = 100 TRX)
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-universal-spokepool <sp1-helios-address> [--testnet]
 */

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import { deployContract, encodeArgs, tronToEvmAddress, resolveChainId, TRON_TESTNET_CHAIN_ID } from "../deploy";

// WTRX (Wrapped TRX) contract address
const WTRX_ADDRESS = "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR";

/** Read and cache generated/constants.json. */
function readConstants(): any {
  const constantsPath = path.resolve(__dirname, "../../../generated/constants.json");
  return JSON.parse(fs.readFileSync(constantsPath, "utf-8"));
}

/** Read deployed-addresses.json and return the HubPool address for the hub chain. */
function getHubPoolAddress(hubChainId: string): string {
  const jsonPath = path.resolve(__dirname, "../../../broadcast/deployed-addresses.json");
  const data = JSON.parse(fs.readFileSync(jsonPath, "utf-8"));
  const address = data.chains?.[hubChainId]?.contracts?.HubPool?.address;
  if (!address) {
    console.log(`Error: HubPool not found in deployed-addresses.json for chain ${hubChainId}`);
    process.exit(1);
  }
  return address;
}

/** Return the already-deployed Tron SpokePool proxy address for this chain, if present. */
function getExistingSpokePoolProxyAddress(chainId: string): string | undefined {
  const deployedAddressesPath = path.resolve(__dirname, "../../../broadcast/deployed-addresses.json");
  if (fs.existsSync(deployedAddressesPath)) {
    const deployedAddresses = JSON.parse(fs.readFileSync(deployedAddressesPath, "utf-8"));
    const address = deployedAddresses.chains?.[chainId]?.contracts?.SpokePool?.address;
    if (address) return address;
  }

  const proxyBroadcastPath = path.resolve(
    __dirname,
    `../../../broadcast/TronDeploySpokePool.s.sol/${chainId}/run-latest.json`
  );
  if (fs.existsSync(proxyBroadcastPath)) {
    const proxyBroadcast = JSON.parse(fs.readFileSync(proxyBroadcastPath, "utf-8"));
    const address = proxyBroadcast.transactions?.find((tx: any) => tx.contractName === "SpokePool")?.contractAddress;
    if (address) return address;
  }
}

/** Read the HubPoolStore address from generated/constants.json, matching the Solidity deploy script logic. */
function getHubPoolStoreAddress(constants: any, hubChainId: string): string {
  const address = constants.L1_ADDRESS_MAP?.[hubChainId]?.hubPoolStore;
  if (!address) {
    console.log(`Error: hubPoolStore not found in constants.json for hub chain ${hubChainId}`);
    process.exit(1);
  }
  return address;
}

async function main(): Promise<void> {
  // First positional arg (skip flags like --testnet)
  const sp1HeliosAddress = process.argv.slice(2).find((a) => !a.startsWith("-"));
  if (!sp1HeliosAddress) {
    console.log("Usage: yarn tron-deploy-universal-spokepool <sp1-helios-address> [--testnet]");
    process.exit(1);
  }

  const chainId = resolveChainId();
  const hubChainId = chainId === TRON_TESTNET_CHAIN_ID ? "11155111" : "1";

  console.log("=== Universal_SpokePool Tron Deployment ===");
  console.log(`Chain ID: ${chainId}`);
  console.log(`Hub Chain ID: ${hubChainId}`);

  const constants = readConstants();

  const adminUpdateBuffer = 86400; // 1 day, matching DeployUniversalSpokePool.s.sol
  const heliosAddress = tronToEvmAddress(sp1HeliosAddress);
  const hubPoolStoreAddress = getHubPoolStoreAddress(constants, hubChainId);
  const hubPoolAddress = getHubPoolAddress(hubChainId);
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
  console.log(`  HubPool:              ${hubPoolAddress}`);
  console.log(`  Wrapped native token: ${wrappedNativeToken}`);
  console.log(`  Deposit quote buffer: ${depositQuoteTimeBuffer}s`);
  console.log(`  Fill deadline buffer: ${fillDeadlineBuffer}s`);
  console.log(`  L2 USDC:              ${l2Usdc} (disabled — CCTP not supported on Tron)`);
  console.log(`  CCTP TokenMessenger:  ${cctpTokenMessenger} (disabled)`);
  console.log(`  OFT dst EID:          ${oftDstEid} (disabled — OFT not supported on Tron)`);
  console.log(`  OFT fee cap:          ${oftFeeCap} (disabled)`);

  // Step 1: Deploy implementation contract
  console.log("\n--- Deploying implementation ---");
  const implEncodedArgs = encodeArgs(
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

  const implArtifactPath = path.resolve(
    __dirname,
    "../../../out-tron/Universal_SpokePool.sol/Universal_SpokePool.json"
  );

  const implResult = await deployContract({
    chainId,
    artifactPath: implArtifactPath,
    encodedArgs: implEncodedArgs,
  });

  console.log(`\nImplementation deployed: ${implResult.address}`);

  // Step 2: Deploy ERC1967Proxy pointing to the implementation, with initialize calldata.
  // Matches DeployUniversalSpokePool.s.sol: initialize(1, hubPool, hubPool)
  console.log("\n--- Deploying ERC1967Proxy ---");

  // Universal_SpokePool.initialize(uint32 _initialDepositId, address _crossDomainAdmin, address _withdrawalRecipient)
  // selector: initialize(uint32,address,address)
  const initCalldata = encodeArgs(["uint32", "address", "address"], [1, hubPoolAddress, hubPoolAddress]);

  // Compute the full initialize calldata with function selector.
  // initialize(uint32,address,address) selector = 0x1794bb3c — but let's compute it properly.
  // We need abi.encodeWithSelector, which is selector + args.
  // The initialize function signature from Universal_SpokePool:
  //   function initialize(uint32 _initialDepositId, address _crossDomainAdmin, address _withdrawalRecipient)
  const { TronWeb } = await import("tronweb");
  const twUtil = new TronWeb({ fullHost: "http://localhost" });
  const initSelector = twUtil.sha3("initialize(uint32,address,address)").slice(0, 10); // 0x + 8 hex chars
  // initCalldata from encodeArgs starts with 0x, strip it to concat with selector
  const initData = initSelector + initCalldata.slice(2);

  // ERC1967Proxy constructor: (address _logic, bytes memory _data)
  const proxyEncodedArgs = encodeArgs(["address", "bytes"], [tronToEvmAddress(implResult.address), initData]);

  const proxyArtifactPath = path.resolve(__dirname, "../../../out-tron/ERC1967Proxy.sol/ERC1967Proxy.json");
  const existingProxyAddress = getExistingSpokePoolProxyAddress(chainId);

  if (existingProxyAddress) {
    console.log(`\nProxy already deployed: ${existingProxyAddress}`);
    console.log(`Skipping proxy deployment and leaving implementation at: ${implResult.address}`);
    return;
  }

  const proxyResult = await deployContract({
    chainId,
    artifactPath: proxyArtifactPath,
    encodedArgs: proxyEncodedArgs,
    contractNameOverride: "SpokePool",
  });

  console.log(`\nProxy deployed: ${proxyResult.address}`);
  console.log(`Implementation: ${implResult.address}`);
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
