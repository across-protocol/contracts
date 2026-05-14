#!/usr/bin/env ts-node

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import { getAddress } from "ethers/lib/utils";
import { ethers } from "../../utils/utils";
import { getNodeUrl } from "../../utils";

const REPO_ROOT = path.resolve(__dirname, "../..");
const BROADCAST_DIR = path.join(REPO_ROOT, "broadcast");
const DEPLOYED_ADDRESSES_PATH = path.join(BROADCAST_DIR, "deployed-addresses.json");
const SAFE_BROADCAST_DIR = path.join(BROADCAST_DIR, "DeploySafe.s.sol");
const UNIVERSAL_BROADCAST_DIR = path.join(BROADCAST_DIR, "DeployUniversalSpokePool.s.sol");
const TRON_UNIVERSAL_BROADCAST_DIR = path.join(BROADCAST_DIR, "TronDeployUniversal_SpokePool.s.sol");
const DEFAULT_OUTPUT_PATH = path.resolve(__dirname, "MULTISIGS.md");

const NON_EVM_CHAIN_IDS = new Set<number>([
  728126428, // TRON — needs TronWeb, not JsonRpcProvider
  133268194659241, // Solana Devnet
  34268394551451, // Solana
]);

const OWNABLE_ABI = ["function owner() view returns (address)"];
const AWM_ABI = ["function owner() view returns (address)", "function directWithdrawer() view returns (address)"];

type SpokePoolType = "universal" | "native" | "none";

interface ChainEntry {
  chainId: number;
  chainName: string;
  spokePoolAddress?: string;
  spokePoolType: SpokePoolType;
  safeAddress?: string;
  adminWithdrawManagerAddress?: string;
  universalOwner?: string;
  universalOwnerError?: string;
  awmOwner?: string;
  awmDirectWithdrawer?: string;
  awmError?: string;
  skippedNonEvm?: boolean;
}

function loadJson(p: string): any {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function getArg(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function readSafeAddress(chainId: number): string | undefined {
  const file = path.join(SAFE_BROADCAST_DIR, String(chainId), "run-latest.json");
  if (!fs.existsSync(file)) return undefined;
  const broadcast = loadJson(file);
  const tx = (broadcast.transactions || []).find(
    (t: { contractName?: string; contractAddress?: string }) =>
      t.contractName === "Safe" && typeof t.contractAddress === "string"
  );
  return tx ? getAddress(tx.contractAddress) : undefined;
}

function detectSpokePoolType(chainId: number, spokePoolAddress: string | undefined): SpokePoolType {
  if (!spokePoolAddress) return "none";
  const universalEvm = path.join(UNIVERSAL_BROADCAST_DIR, String(chainId), "run-latest.json");
  const universalTron = path.join(TRON_UNIVERSAL_BROADCAST_DIR, String(chainId), "run-latest.json");
  if (fs.existsSync(universalEvm) || fs.existsSync(universalTron)) return "universal";
  return "native";
}

async function fetchOwner(provider: ethers.providers.Provider, address: string): Promise<string> {
  const contract = new ethers.Contract(address, OWNABLE_ABI, provider);
  return getAddress(await contract.owner());
}

async function fetchAwmState(
  provider: ethers.providers.Provider,
  address: string
): Promise<{ owner: string; directWithdrawer: string }> {
  const contract = new ethers.Contract(address, AWM_ABI, provider);
  const [owner, directWithdrawer] = await Promise.all([contract.owner(), contract.directWithdrawer()]);
  return { owner: getAddress(owner), directWithdrawer: getAddress(directWithdrawer) };
}

function resolveProvider(chainId: number): ethers.providers.JsonRpcProvider | undefined {
  try {
    const url = getNodeUrl(chainId);
    if (!url) return undefined;
    return new ethers.providers.JsonRpcProvider(url);
  } catch {
    return undefined;
  }
}

function safeChecksum(addr: string | undefined): string | undefined {
  if (!addr) return undefined;
  try {
    return getAddress(addr);
  } catch {
    return addr;
  }
}

async function buildEntry(chainId: number, info: { chain_name?: string; contracts?: any }): Promise<ChainEntry> {
  const contracts = info.contracts ?? {};
  const spokePoolAddress = safeChecksum(contracts.SpokePool?.address);
  const adminWithdrawManagerAddress = safeChecksum(contracts.AdminWithdrawManager?.address);
  const safeAddress = readSafeAddress(chainId);
  const spokePoolType = detectSpokePoolType(chainId, spokePoolAddress);

  const entry: ChainEntry = {
    chainId,
    chainName: info.chain_name ?? `Chain ${chainId}`,
    spokePoolAddress,
    spokePoolType,
    safeAddress,
    adminWithdrawManagerAddress,
  };

  if (NON_EVM_CHAIN_IDS.has(chainId)) {
    entry.skippedNonEvm = true;
    return entry;
  }

  const provider = resolveProvider(chainId);
  if (!provider) {
    const msg = "no RPC available";
    if (spokePoolType === "universal") entry.universalOwnerError = msg;
    if (adminWithdrawManagerAddress) entry.awmError = msg;
    return entry;
  }

  const tasks: Promise<unknown>[] = [];

  if (spokePoolType === "universal" && spokePoolAddress) {
    tasks.push(
      fetchOwner(provider, spokePoolAddress)
        .then((owner) => {
          entry.universalOwner = owner;
        })
        .catch((err: Error) => {
          entry.universalOwnerError = err.message;
        })
    );
  }

  if (adminWithdrawManagerAddress) {
    tasks.push(
      fetchAwmState(provider, adminWithdrawManagerAddress)
        .then((state) => {
          entry.awmOwner = state.owner;
          entry.awmDirectWithdrawer = state.directWithdrawer;
        })
        .catch((err: Error) => {
          entry.awmError = err.message;
        })
    );
  }

  await Promise.all(tasks);
  return entry;
}

function eqAddr(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  return a.toLowerCase() === b.toLowerCase();
}

function migrationStatus(actual: string | undefined, safe: string | undefined, error: string | undefined): string {
  if (error) return `? (${error})`;
  if (!actual) return "—";
  if (!safe) return `${actual} (no Safe)`;
  return eqAddr(actual, safe) ? "✓ Safe" : `✗ ${actual}`;
}

function renderMarkdown(entries: ChainEntry[]): string {
  const lines: string[] = [];
  lines.push("# Safe Multisig Migration Status");
  lines.push("");
  lines.push("Generated by `script/safe-multisig/generateMultisigList.ts`.");
  lines.push("");
  lines.push("Lists every chain with a `SpokePool` entry in `broadcast/deployed-addresses.json` and, for each:");
  lines.push("- the chain's Safe multisig (from `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`)");
  lines.push(
    "- whether the SpokePool is a `Universal_SpokePool` and, if so, whether its on-chain `owner()` is the Safe"
  );
  lines.push(
    "- whether the chain's `AdminWithdrawManager` has migrated `owner()` and `directWithdrawer()` to the Safe"
  );
  lines.push("");
  lines.push(
    "Status legend: `✓ Safe` = address matches the chain's Safe. `✗ <addr>` = mismatch, shows current value. `—` = not applicable. `? (...)` = RPC error."
  );
  lines.push("");
  lines.push("| Chain ID | Chain | SpokePool | Safe | Universal owner | AWM owner | AWM directWithdrawer |");
  lines.push("| --- | --- | --- | --- | --- | --- | --- |");

  for (const entry of entries) {
    const safeCell = entry.safeAddress ?? "no Safe deployment";
    const typeCell =
      entry.spokePoolType === "universal" ? "Universal" : entry.spokePoolType === "native" ? "Native" : "—";

    let universalCell: string;
    if (entry.spokePoolType !== "universal") {
      universalCell = "—";
    } else if (entry.skippedNonEvm) {
      universalCell = "— (non-EVM)";
    } else {
      universalCell = migrationStatus(entry.universalOwner, entry.safeAddress, entry.universalOwnerError);
    }

    let awmOwnerCell: string;
    let awmDwCell: string;
    if (!entry.adminWithdrawManagerAddress) {
      awmOwnerCell = "—";
      awmDwCell = "—";
    } else if (entry.skippedNonEvm) {
      awmOwnerCell = "— (non-EVM)";
      awmDwCell = "— (non-EVM)";
    } else {
      awmOwnerCell = migrationStatus(entry.awmOwner, entry.safeAddress, entry.awmError);
      awmDwCell = migrationStatus(entry.awmDirectWithdrawer, entry.safeAddress, entry.awmError);
    }

    lines.push(
      `| ${entry.chainId} | ${entry.chainName} | ${typeCell} | ${safeCell} | ${universalCell} | ${awmOwnerCell} | ${awmDwCell} |`
    );
  }

  lines.push("");
  return lines.join("\n");
}

async function main() {
  if (process.argv.includes("--help")) {
    console.log(`Usage: yarn ts-node ./script/safe-multisig/generateMultisigList.ts [--output <path>]

Scans broadcast/deployed-addresses.json for chains with a SpokePool deployment, then for each chain:
- looks up the deployed Safe in broadcast/DeploySafe.s.sol/<chainId>/run-latest.json
- if the SpokePool is a Universal_SpokePool, calls owner() to check Safe migration
- if AdminWithdrawManager is deployed, calls owner() and directWithdrawer() to check Safe migration

Writes the result as a markdown table. Defaults output to script/safe-multisig/MULTISIGS.md.

Env vars: NODE_URL_<chainId> or CUSTOM_NODE_URL provide the RPC. Falls back to PUBLIC_NETWORKS publicRPC.
`);
    return;
  }

  const outputPath = path.resolve(getArg("--output") ?? DEFAULT_OUTPUT_PATH);
  const deployed = loadJson(DEPLOYED_ADDRESSES_PATH);
  const chainIds = Object.keys(deployed.chains)
    .map(Number)
    .filter((cid) => Number.isInteger(cid) && deployed.chains[String(cid)]?.contracts?.SpokePool?.address)
    .sort((a, b) => a - b);

  console.log(`Building migration report for ${chainIds.length} chain(s)...`);
  const entries = await Promise.all(
    chainIds.map(async (cid) => {
      const entry = await buildEntry(cid, deployed.chains[String(cid)]);
      console.log(`  ✓ ${cid} ${entry.chainName}`);
      return entry;
    })
  );

  const markdown = renderMarkdown(entries);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, markdown);
  console.log(`\nWrote ${entries.length} rows to ${outputPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
