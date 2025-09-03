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
  AZERO_GAS_PRICE,
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

// Helper function to extract wrapped native tokens from TOKEN_SYMBOLS_MAP
function extractWrappedNativeTokens(): { [key: string]: string } {
  const result: { [key: string]: string } = {};

  // Extract WETH addresses for each chain
  for (const [chainId, addresses] of Object.entries(WETH)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = addresses;
    }
  }

  return result;
}

// Helper function to extract USDC addresses
function extractUsdcAddresses(): { [key: string]: string } {
  const result: { [key: string]: string } = {};

  for (const [chainId, address] of Object.entries(USDC)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = address;
    }
  }

  return result;
}

// Helper function to extract USDCe addresses
function extractUsdceAddresses(): { [key: string]: string } {
  const result: { [key: string]: string } = {};

  for (const [chainId, address] of Object.entries(USDCe)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = address;
    }
  }

  return result;
}

// Helper function to extract WGHO addresses
function extractWghoAddresses(): { [key: string]: string } {
  const result: { [key: string]: string } = {};

  for (const [chainId, address] of Object.entries(WGHO)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = address;
    }
  }

  return result;
}

// Helper function to convert L1_ADDRESS_MAP to the expected format
function convertL1Addresses(): { [key: string]: { [key: string]: string } } {
  const result: { [key: string]: { [key: string]: string } } = {};

  for (const [chainId, addresses] of Object.entries(L1_ADDRESS_MAP)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = addresses;
    }
  }

  return result;
}

// Helper function to convert L2_ADDRESS_MAP to the expected format
function convertL2Addresses(): { [key: string]: { [key: string]: string } } {
  const result: { [key: string]: { [key: string]: string } } = {};

  for (const [chainId, addresses] of Object.entries(L2_ADDRESS_MAP)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = addresses;
    }
  }

  return result;
}

// Helper function to convert OP_STACK_ADDRESS_MAP to the expected format
function convertOpStackAddresses(): { [key: string]: { [key: string]: { [key: string]: string } } } {
  const result: { [key: string]: { [key: string]: { [key: string]: string } } } = {};

  for (const [hubChainId, spokeChains] of Object.entries(OP_STACK_ADDRESS_MAP)) {
    const hubChainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(hubChainId)
    );
    if (hubChainName) {
      result[hubChainName] = {};
      for (const [spokeChainId, addresses] of Object.entries(spokeChains)) {
        const spokeChainName = Object.keys(CHAIN_IDs).find(
          (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(spokeChainId)
        );
        if (spokeChainName) {
          result[hubChainName][spokeChainName] = addresses;
        }
      }
    }
  }

  return result;
}

// Helper function to convert OFT_EIDs to the expected format
function convertOftEids(): { [key: string]: number } {
  const result: { [key: string]: number } = {};

  for (const [chainId, eid] of OFT_EIDs.entries()) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = eid;
    }
  }

  return result;
}

// Helper function to convert CIRCLE_DOMAIN_IDs to the expected format
function convertCircleDomainIds(): { [key: string]: number } {
  const result: { [key: string]: number } = {};

  for (const [chainId, domainId] of Object.entries(CIRCLE_DOMAIN_IDs)) {
    const chainName = Object.keys(CHAIN_IDs).find(
      (key) => CHAIN_IDs[key as keyof typeof CHAIN_IDs] === Number(chainId)
    );
    if (chainName) {
      result[chainName] = domainId;
    }
  }

  return result;
}

// Generate the constants.json structure
function generateConstantsJson() {
  const constants = {
    chainIds: convertChainIdsToObject(CHAIN_IDs),
    oftEids: convertOftEids(),
    wrappedNativeTokens: extractWrappedNativeTokens(),
    l2Addresses: convertL2Addresses(),
    l1Addresses: convertL1Addresses(),
    opStackAddresses: convertOpStackAddresses(),
    circleDomainIds: convertCircleDomainIds(),
    timeConstants: {
      QUOTE_TIME_BUFFER: QUOTE_TIME_BUFFER,
      FILL_DEADLINE_BUFFER: FILL_DEADLINE_BUFFER,
    },
    usdcAddresses: extractUsdcAddresses(),
    usdceAddresses: extractUsdceAddresses(),
    wghoAddresses: extractWghoAddresses(),
    otherConstants: {
      ZERO_ADDRESS: ZERO_ADDRESS,
      ARBITRUM_MAX_SUBMISSION_COST: ARBITRUM_MAX_SUBMISSION_COST,
      AZERO_GAS_PRICE: AZERO_GAS_PRICE,
      CIRCLE_UNINITIALIZED_DOMAIN_ID: CIRCLE_UNINITIALIZED_DOMAIN_ID,
      ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT: ZK_L1_GAS_TO_L2_GAS_PER_PUBDATA_LIMIT,
      ZK_L2_GAS_LIMIT: ZK_L2_GAS_LIMIT,
      ZK_MAX_GASPRICE: ZK_MAX_GASPRICE,
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
    const outputPath = path.join(__dirname, "../script/utils/constants.json");
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
