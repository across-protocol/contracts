#!/usr/bin/env ts-node
/**
 * Upgrades the live CounterfactualBeacon proxy on Tron to a new chain-specific implementation via
 * UUPS `upgradeToAndCall(newImpl, "")` — the out-of-band owner step that tron-deploy-counterfactual-beacon
 * deliberately does not perform (it is deploy-only and never moves a live beacon).
 *
 * onlyOwner: the signing key (MNEMONIC account 0) must be the beacon's Ownable2Step owner.
 *
 * Preflight: requires owner() == deployer and proxiableUUID() on the new impl == the ERC1967 impl slot
 * (i.e. the target really is a UUPS CounterfactualBeacon impl). Post-check: reads a getter through the
 * proxy and prints it, so a wrong/stale target is caught immediately.
 *
 * Options:
 *   --testnet  — Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-upgrade-counterfactual-beacon [<newImpl>] [--testnet]
 *     newImpl — optional CounterfactualBeacon impl address (Tron Base58Check, T...); defaults to the
 *               most recent tron-deploy-counterfactual-beacon-impl broadcast for this chain
 */

import "dotenv/config";
import { TronWeb } from "tronweb";
import { callContract, initTronWeb, validateTronAddress, resolveChainId, readBroadcastAddress } from "../deploy";

// keccak256("eip1967.proxy.implementation") - 1 — what proxiableUUID() must return for a UUPS impl.
const ERC1967_IMPL_SLOT = "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

/** Constant-call a view function; returns the raw hex words, or null if the call reverted. */
async function constantCall(
  tronWeb: TronWeb,
  from: string,
  contract: string,
  functionSelector: string
): Promise<string | null> {
  const res = await tronWeb.transactionBuilder.triggerConstantContract(contract, functionSelector, {}, [], from);
  if (!res?.result?.result) return null;
  return res.constant_result?.[0] ?? null;
}

async function main(): Promise<void> {
  const chainId = resolveChainId();
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));

  const proxy = readBroadcastAddress("CounterfactualBeaconProxy", chainId);
  if (!proxy) {
    console.log("Error: no CounterfactualBeaconProxy broadcast for this chain (nothing to upgrade).");
    process.exit(1);
  }

  const newImpl = args[0] ?? readBroadcastAddress("CounterfactualBeacon", chainId);
  if (!newImpl) {
    console.log(
      "Error: no CounterfactualBeacon impl broadcast for this chain and no impl address passed.\n" +
        "Run tron-deploy-counterfactual-beacon-impl first, or pass the impl address explicitly."
    );
    process.exit(1);
  }
  validateTronAddress(newImpl, "newImpl");

  const { tronWeb, deployerAddress } = initTronWeb(chainId);

  console.log("=== CounterfactualBeacon proxy upgrade ===");
  console.log(`Chain ID: ${chainId}`);
  console.log(`Proxy:    ${proxy}`);
  console.log(`New impl: ${newImpl}`);

  // Preflight 1: the signer must be the beacon owner (Ownable2Step; upgradeToAndCall is onlyOwner).
  const ownerWord = await constantCall(tronWeb, deployerAddress, proxy, "owner()");
  const owner = ownerWord ? tronWeb.address.fromHex("41" + ownerWord.slice(-40)) : null;
  if (owner !== deployerAddress) {
    console.log(`Error: beacon owner is ${owner}, but the signing key is ${deployerAddress}.`);
    process.exit(1);
  }

  // Preflight 2: the target must be a UUPS impl (a wrong address would revert the upgrade, or worse,
  // an upgradeable-but-wrong contract would brick the beacon).
  const uuid = await constantCall(tronWeb, deployerAddress, newImpl, "proxiableUUID()");
  if (uuid !== ERC1967_IMPL_SLOT) {
    console.log(`Error: newImpl.proxiableUUID() returned ${uuid ?? "<revert>"} — not a UUPS implementation.`);
    process.exit(1);
  }

  await callContract({
    chainId,
    contract: proxy,
    functionSelector: "upgradeToAndCall(address,bytes)",
    parameters: [
      { type: "address", value: newImpl },
      { type: "bytes", value: "0x" },
    ],
  });

  // Post-check: `usdce()` only exists on current-generation impls, so a successful read through the
  // proxy proves the upgrade landed; older impls revert here.
  const usdce = await constantCall(tronWeb, deployerAddress, proxy, "usdce()");
  if (usdce === null) {
    console.log("WARNING: proxy.usdce() reverted after the upgrade — verify the impl slot manually!");
    process.exit(1);
  }
  const usdt = await constantCall(tronWeb, deployerAddress, proxy, "usdt()");
  console.log("=== Upgrade complete ===");
  console.log(`proxy.usdce() = ${tronWeb.address.fromHex("41" + usdce.slice(-40))}`);
  console.log(`proxy.usdt()  = ${usdt ? tronWeb.address.fromHex("41" + usdt.slice(-40)) : "<revert>"}`);
  console.log("Next: re-run CheckCounterfactualDeployments (Tron beacon getters) to verify the full config.");
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
