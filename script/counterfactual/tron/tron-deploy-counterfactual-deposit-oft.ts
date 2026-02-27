#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositOFT to Tron.
 *
 * Constructor args:
 *   oftSrcPeriphery — SponsoredOFTSrcPeriphery contract address (0x hex)
 *   srcEid          — OFT source endpoint ID (uint32)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-oft <chain-id> <oftSrcPeriphery> <srcEid>
 */

import "dotenv/config";
import * as path from "path";
import { utils } from "ethers";
import { deployContract } from "./deploy";

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

async function main(): Promise<void> {
  const chainId = process.argv[2];
  const oftSrcPeriphery = process.argv[3];
  const srcEid = process.argv[4];

  if (!chainId || !oftSrcPeriphery || !srcEid) {
    console.log("Usage: yarn tron-deploy-counterfactual-deposit-oft <chain-id> <oftSrcPeriphery> <srcEid>");
    process.exit(1);
  }

  // Validate address format.
  if (!ADDRESS_RE.test(oftSrcPeriphery)) {
    console.log(`Error: invalid oftSrcPeriphery "${oftSrcPeriphery}". Expected 0x-prefixed 20-byte hex.`);
    process.exit(1);
  }

  // Validate uint32 range.
  const eidNum = parseInt(srcEid, 10);
  if (isNaN(eidNum) || eidNum < 0 || eidNum > 0xffffffff) {
    console.log(`Error: invalid srcEid "${srcEid}". Expected uint32.`);
    process.exit(1);
  }

  // ABI-encode constructor args: (address oftSrcPeriphery, uint32 srcEid).
  const encodedArgs = utils.defaultAbiCoder.encode(["address", "uint32"], [oftSrcPeriphery, eidNum]);

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositOFT.sol/CounterfactualDepositOFT.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
