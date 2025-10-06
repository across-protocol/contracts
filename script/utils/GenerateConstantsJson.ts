#!/usr/bin/env ts-node

import * as fs from "fs";
import * as path from "path";

// Import the constants from the TypeScript files
import { CHAIN_IDs, PUBLIC_NETWORKS, TESTNET_CHAIN_IDs, TOKEN_SYMBOLS_MAP, ChainFamily } from "../../utils/constants";
import {
  ZERO_ADDRESS,
  USDC,
  USDCe,
  WETH,
  WGHO,
  WMATIC,
  QUOTE_TIME_BUFFER,
  FILL_DEADLINE_BUFFER,
  ARBITRUM_MAX_SUBMISSION_COST,
  CIRCLE_UNINITIALIZED_DOMAIN_ID,
  ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT,
  ZK_L2_GAS_LIMIT,
  ZK_MAX_GASPRICE,
  L1_ADDRESS_MAP,
  OP_STACK_ADDRESS_MAP,
  L2_ADDRESS_MAP,
} from "../../deploy/consts";

const convertChainFamiliesEnumString = () => {
  const publicNetworksWithEnum = Object.fromEntries(
    Object.entries(PUBLIC_NETWORKS).map(([key, value]) => [
      key,
      {
        ...value,
        family: ChainFamily[value.family],
      },
    ])
  );

  return publicNetworksWithEnum;
};

/**
 * Convert the chain IDs object to the expected format
 * @returns { [key: string]: number }
 * @example
 * {
 *   "1": 1,
 *   "10": 10,
 *   "56": 56,
 *   "137": 137,
 * }
 */
const convertChainIdsToObject = (): { [key: string]: number } =>
  Object.fromEntries(Object.entries(CHAIN_IDs).map(([chainIdName, chainId]) => [chainIdName, chainId]));

/**
 * Generate the wrapped native tokens for the public networks
 * @returns { [key: string]: string }
 * @example
 * {
 *   "1": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
 *   "10": "0x4200000000000000000000000000000000000006",
 *   "56": "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
 *   "137": "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
 * }
 */
function generateWrappedNativeTokens(): { [key: string]: string } {
  const result: { [key: string]: string } = {};
  for (const [key, value] of Object.entries(PUBLIC_NETWORKS)) {
    const nativeToken = value.nativeToken;
    const wrappedPrefix = "W";
    const wrappedNativeSymbol = `${wrappedPrefix}${nativeToken}`;

    // Check if the wrapped token symbol exists in TOKEN_SYMBOLS_MAP
    if (wrappedNativeSymbol in TOKEN_SYMBOLS_MAP) {
      const tokenInfo = TOKEN_SYMBOLS_MAP[wrappedNativeSymbol as keyof typeof TOKEN_SYMBOLS_MAP];
      const wrappedNativeToken = tokenInfo.addresses[Number(key)];
      result[key] = wrappedNativeToken;
    } else {
      console.warn(
        `Warning: Wrapped token symbol "${wrappedNativeSymbol}" not found in TOKEN_SYMBOLS_MAP for chain ${key}`
      );
    }
  }
  return result;
}

// Generate the constants.json structure
function generateConstantsJson() {
  const constants = {
    PUBLIC_NETWORKS: convertChainFamiliesEnumString(),
    CHAIN_IDs: convertChainIdsToObject(),
    TESTNET_CHAIN_IDs: Object.values(TESTNET_CHAIN_IDs),
    WETH,
    WRAPPED_NATIVE_TOKENS: generateWrappedNativeTokens(),
    L2_ADDRESS_MAP,
    L1_ADDRESS_MAP,
    OP_STACK_ADDRESS_MAP,
    TIME_CONSTANTS: {
      QUOTE_TIME_BUFFER,
      FILL_DEADLINE_BUFFER,
    },
    USDC,
    USDCe,
    WGHO,
    WMATIC,
    OTHER_CONSTANTS: {
      ZERO_ADDRESS,
      ARBITRUM_MAX_SUBMISSION_COST,
      CIRCLE_UNINITIALIZED_DOMAIN_ID,
      ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT,
      ZK_L2_GAS_LIMIT,
      ZK_MAX_GASPRICE,
    },
  };

  return constants;
}

// Main function
function main() {
  try {
    console.log("Generating constants.json...");

    const constants = generateConstantsJson();

    // Write to generated/constants.json
    const outputPath = "generated/constants.json";
    const outputDir = path.dirname(outputPath);

    // Ensure the directory exists
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    fs.writeFileSync(outputPath, JSON.stringify(constants, null, 2) + "\n");

    console.log(`✅ Successfully generated constants.json at ${outputPath}`);
    console.log(`📊 Generated ${Object.keys(constants.CHAIN_IDs).length} chain IDs`);
    console.log(`📊 Generated ${Object.keys(constants.L1_ADDRESS_MAP).length} L1 address mappings`);
    console.log(`📊 Generated ${Object.keys(constants.L2_ADDRESS_MAP).length} L2 address mappings`);
  } catch (error) {
    console.error("❌ Error generating constants.json:", error);
    process.exit(1);
  }
}

// Run the script
if (require.main === module) {
  main();
}
