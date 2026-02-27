#!/usr/bin/env ts-node
/**
 * Deploys CounterfactualDepositCCTP to Tron.
 *
 * Constructor args:
 *   srcPeriphery  — SponsoredCCTPSrcPeriphery contract address (0x hex)
 *   sourceDomain  — CCTP source domain ID (uint32)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-deposit-cctp <chain-id> <srcPeriphery> <sourceDomain>
 */

import "dotenv/config";
import * as path from "path";
import { utils } from "ethers";
import { deployContract } from "./deploy";

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

async function main(): Promise<void> {
  const chainId = process.argv[2];
  const srcPeriphery = process.argv[3];
  const sourceDomain = process.argv[4];

  if (!chainId || !srcPeriphery || !sourceDomain) {
    console.log("Usage: yarn tron-deploy-counterfactual-deposit-cctp <chain-id> <srcPeriphery> <sourceDomain>");
    process.exit(1);
  }

  // Validate address format.
  if (!ADDRESS_RE.test(srcPeriphery)) {
    console.log(`Error: invalid srcPeriphery "${srcPeriphery}". Expected 0x-prefixed 20-byte hex.`);
    process.exit(1);
  }

  // Validate uint32 range.
  const domainNum = parseInt(sourceDomain, 10);
  if (isNaN(domainNum) || domainNum < 0 || domainNum > 0xffffffff) {
    console.log(`Error: invalid sourceDomain "${sourceDomain}". Expected uint32.`);
    process.exit(1);
  }

  // ABI-encode constructor args: (address srcPeriphery, uint32 sourceDomain).
  const encodedArgs = utils.defaultAbiCoder.encode(["address", "uint32"], [srcPeriphery, domainNum]);

  const artifactPath = path.resolve(
    __dirname,
    "../../../out-tron/CounterfactualDepositCCTP.sol/CounterfactualDepositCCTP.json"
  );

  await deployContract({ chainId, artifactPath, encodedArgs });
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
