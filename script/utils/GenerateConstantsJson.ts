#!/usr/bin/env ts-node

import * as fs from "fs";
import * as path from "path";

// Import the constants from the TypeScript files
import { CHAIN_IDs, PUBLIC_NETWORKS } from "../../utils/constants";
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

// Generate the constants.json structure
function generateConstantsJson() {
  const constants = {
    PUBLIC_NETWORKS,
    CHAIN_IDs: convertChainIdsToObject(CHAIN_IDs),
    WETH,
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

    // Write to script/utils/constants.json
    const outputPath = path.join(__dirname, "./constants.json");
    const outputDir = path.dirname(outputPath);

    // Ensure the directory exists
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    fs.writeFileSync(outputPath, JSON.stringify(constants, null, 2));

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
