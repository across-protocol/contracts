#!/usr/bin/env ts-node

import * as fs from "fs";
import * as path from "path";

// Import the constants from the TypeScript files
import { CHAIN_IDs } from "../../utils/constants";
import {
  ZERO_ADDRESS,
  USDC,
  USDCe,
  WETH,
  WGHO,
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
  CIRCLE_DOMAIN_IDs,
  OFT_EIDs,
} from "../../deploy/consts";

// Helper function to convert chain IDs object to the expected format
function convertChainIdsToObject(chainIds: any): { [key: string]: number } {
  const result: { [key: string]: number } = {};
  for (const [key, value] of Object.entries(chainIds)) {
    if (typeof value === "number") {
      result[key] = value;
    }
  }
  return result;
}

// Helper function to convert OFT_EIDs to the expected format
function filterInvalidValues(values: { [key: string]: number }): { [key: string]: number } {
  const result: { [key: string]: number } = {};

  for (const [chainId, eid] of Object.entries(values)) {
    if (eid === -1) {
      continue;
    }
    result[chainId] = eid;
  }

  return result;
}

// Generate the constants.json structure
function generateConstantsJson() {
  const constants = {
    chainIds: convertChainIdsToObject(CHAIN_IDs),
    oftEids: filterInvalidValues(Object.fromEntries(OFT_EIDs)),
    wrappedNativeTokens: WETH,
    l2Addresses: L2_ADDRESS_MAP,
    l1Addresses: L1_ADDRESS_MAP,
    opStackAddresses: OP_STACK_ADDRESS_MAP,
    circleDomainIds: filterInvalidValues(CIRCLE_DOMAIN_IDs),
    timeConstants: {
      QUOTE_TIME_BUFFER,
      FILL_DEADLINE_BUFFER,
    },
    usdcAddresses: USDC,
    usdceAddresses: USDCe,
    wghoAddresses: WGHO,
    otherConstants: {
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

    // Write to script/utils/constants.json
    const outputPath = path.join(__dirname, "./constants.json");
    const outputDir = path.dirname(outputPath);

    // Ensure the directory exists
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    fs.writeFileSync(outputPath, JSON.stringify(constants, null, 2));

    console.log(`✅ Successfully generated constants.json at ${outputPath}`);
    console.log(`📊 Generated ${Object.keys(constants.chainIds).length} chain IDs`);
    console.log(`📊 Generated ${Object.keys(constants.l1Addresses).length} L1 address mappings`);
    console.log(`📊 Generated ${Object.keys(constants.l2Addresses).length} L2 address mappings`);
  } catch (error) {
    console.error("❌ Error generating constants.json:", error);
    process.exit(1);
  }
}

// Run the script
if (require.main === module) {
  main();
}
