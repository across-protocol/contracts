#!/usr/bin/env ts-node
/**
 * Add a proposer (a.k.a. Safe Transaction Service "delegate") to a list of Safes
 * across multiple chains, signing each authorization with a connected Ledger.
 *
 * A proposer can ONLY propose transactions to the Safe Transaction Service on
 * behalf of an owner; it is not a signer and cannot approve or execute anything,
 * so it can never move funds. Adding one is an off-chain operation: there is no
 * on-chain transaction and no gas. We sign an EIP-712 message authorizing the
 * delegate and POST it to Safe's hosted Transaction Service.
 *
 * Signing is delegated to `cast wallet sign --ledger` (a Foundry tool). The
 * EIP-712 payload it hashes is byte-identical to what ethers / safe-eth-py
 * produce, so the resulting signature is accepted by Safe's service. The Ledger
 * approves each signature on-device.
 *
 * Usage:
 *   yarn ts-node ./script/safe-multisig/addProposer.ts            # uses proposers.config.json
 *   yarn ts-node ./script/safe-multisig/addProposer.ts --dry-run  # checks only, no signing/POST
 *   yarn ts-node ./script/safe-multisig/addProposer.ts --yes      # skip the confirmation prompt
 *
 * Flags (all optional; defaults come from --config):
 *   --config <path>      JSON config (default: ./proposers.config.json)
 *   --delegate <addr>    Proposer address to add
 *   --delegator <addr>   Owner authorizing the proposer (must sign on the Ledger)
 *   --label <string>     Human-readable label stored alongside the delegate
 *   --hd-path <path>     Ledger derivation path (default Ledger Live: m/44'/60'/0'/0/0)
 *   --safes <a,b,...>    Comma-separated "shortName:address" list (overrides config.safes)
 *   --dry-run            Resolve chains and run ownership/existence checks only
 *   --force              Attempt the POST even if ownership can't be confirmed
 *   --yes                Skip the interactive confirmation prompt
 *
 * Env (optional):
 *   SAFE_API_KEY         If set, sent as `Authorization: Bearer <key>` to api.safe.global
 */
import "dotenv/config";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as readline from "readline";
import { execFileSync } from "child_process";
import { ethers } from "ethers";
import { getAddress } from "ethers/lib/utils";

const CONFIG_SERVICE_URL = "https://safe-config.safe.global/api/v1/chains/?limit=200";
const DEFAULT_CONFIG_PATH = path.resolve(__dirname, "proposers.config.json");
const DEFAULT_HD_PATH = "m/44'/60'/0'/0/0";

// EIP-712 typed data used by the Safe Transaction Service to authorize a delegate.
// Matches @safe-global/api-kit signDelegate.ts exactly (verified against ethers).
const DELEGATE_TYPES = {
  Delegate: [
    { name: "delegateAddress", type: "address" },
    { name: "totp", type: "uint256" },
  ],
} as const;

interface ProposerConfig {
  delegate: string;
  delegator: string;
  label: string;
  hdPath: string;
  safes: string[];
}

interface ChainInfo {
  chainId: number;
  shortName: string;
  chainName: string;
  transactionService: string; // base, e.g. https://api.safe.global/tx-service/eth
}

type Status = "added" | "would-add" | "already-proposer" | "not-owner" | "not-indexed" | "failed";
interface Result {
  entry: string;
  chainName?: string;
  status: Status;
  detail?: string;
}

function getArg(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function authHeaders(): Record<string, string> {
  const key = process.env.SAFE_API_KEY;
  return key ? { Authorization: `Bearer ${key}` } : {};
}

function loadConfig(): ProposerConfig {
  const configPath = getArg("--config") ?? DEFAULT_CONFIG_PATH;
  const parsed = JSON.parse(fs.readFileSync(configPath, "utf8")) as Partial<ProposerConfig>;

  const delegate = getArg("--delegate") ?? parsed.delegate;
  const delegator = getArg("--delegator") ?? parsed.delegator;
  const label = getArg("--label") ?? parsed.label ?? "proposer";
  const hdPath = getArg("--hd-path") ?? parsed.hdPath ?? DEFAULT_HD_PATH;
  const safesArg = getArg("--safes");
  const safes = safesArg ? safesArg.split(",").map((s) => s.trim()) : parsed.safes;

  if (!delegate) throw new Error("Missing delegate (config.delegate or --delegate)");
  if (!delegator) throw new Error("Missing delegator (config.delegator or --delegator)");
  if (!Array.isArray(safes) || safes.length === 0) throw new Error("Missing safes (config.safes or --safes)");

  return {
    delegate: getAddress(delegate),
    delegator: getAddress(delegator),
    label,
    hdPath,
    safes,
  };
}

// Fetch the authoritative chain registry from Safe's config service so we never
// hardcode the tx-service URL or chainId. The URL path segment is NOT always the
// app short-name (e.g. matic -> .../pol, hyper-evm -> .../hyper), which is exactly
// why we read transactionService straight from the service.
async function loadChains(): Promise<Map<string, ChainInfo>> {
  const byShort = new Map<string, ChainInfo>();
  let url: string | null = CONFIG_SERVICE_URL;
  while (url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Safe config service ${url} -> ${res.status} ${await res.text()}`);
    const data: any = await res.json();
    for (const c of data.results ?? []) {
      if (!c.transactionService) continue; // chain has no hosted tx-service
      byShort.set(c.shortName, {
        chainId: Number(c.chainId),
        shortName: c.shortName,
        chainName: c.chainName,
        transactionService: c.transactionService.replace(/\/$/, ""),
      });
    }
    url = data.next;
  }
  return byShort;
}

async function getSafeOwners(txBase: string, safe: string): Promise<string[] | null> {
  const res = await fetch(`${txBase}/api/v1/safes/${safe}/`, { headers: authHeaders() });
  if (res.status === 404) return null; // not indexed by the service
  if (!res.ok) throw new Error(`GET safe info -> ${res.status} ${await res.text()}`);
  const data: any = await res.json();
  return (data.owners ?? []) as string[];
}

async function isAlreadyProposer(txBase: string, safe: string, delegate: string): Promise<boolean> {
  const url = `${txBase}/api/v2/delegates/?safe=${safe}&delegate=${delegate}`;
  const res = await fetch(url, { headers: authHeaders() });
  if (!res.ok) throw new Error(`GET delegates -> ${res.status} ${await res.text()}`);
  const data: any = await res.json();
  const count = data.count ?? (Array.isArray(data.results) ? data.results.length : 0);
  return count > 0;
}

// Sign the delegate authorization on the Ledger via cast and verify locally that
// the recovered address is the expected delegator before returning.
function signDelegate(chainId: number, delegate: string, delegator: string, hdPath: string): string {
  const totp = Math.floor(Date.now() / 1000 / 3600);
  const domain = { name: "Safe Transaction Service", version: "1.0", chainId };
  const message = { delegateAddress: delegate, totp };
  const typedData = {
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
      ],
      ...DELEGATE_TYPES,
      // ^ cast needs the EIP712Domain entry; ethers must NOT receive it.
    },
    primaryType: "Delegate",
    domain,
    message,
  };

  const tmp = path.join(os.tmpdir(), `safe-delegate-${chainId}-${totp}.json`);
  fs.writeFileSync(tmp, JSON.stringify(typedData));
  let stdout: string;
  try {
    console.log(`  -> Approve the EIP-712 signature on your Ledger (chainId ${chainId})...`);
    stdout = execFileSync(
      "cast",
      ["wallet", "sign", "--ledger", "--mnemonic-derivation-path", hdPath, "--data", "--from-file", tmp],
      {
        encoding: "utf8",
        stdio: ["inherit", "pipe", "inherit"],
        env: { ...process.env, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1" },
      }
    );
  } finally {
    fs.rmSync(tmp, { force: true });
  }

  const match = stdout.match(/0x[0-9a-fA-F]{130}/);
  if (!match) throw new Error(`Could not parse signature from cast output: ${stdout.trim()}`);
  const signature = match[0];

  const recovered = ethers.utils.verifyTypedData(domain, DELEGATE_TYPES as any, message, signature);
  if (getAddress(recovered) !== getAddress(delegator)) {
    throw new Error(
      `Ledger signed as ${recovered} but expected delegator ${delegator}. ` +
        `Wrong account/derivation path? Set the correct --hd-path.`
    );
  }
  return signature;
}

async function addProposer(txBase: string, body: Record<string, string>): Promise<void> {
  const res = await fetch(`${txBase}/api/v2/delegates/`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`POST delegates -> ${res.status} ${await res.text()}`);
}

function confirm(question: string): Promise<boolean> {
  if (process.argv.includes("--yes")) return Promise.resolve(true);
  if (!process.stdin.isTTY) throw new Error("Not a TTY; re-run with --yes to confirm non-interactively.");
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} [y/N] `, (a) => {
      rl.close();
      resolve(/^y(es)?$/i.test(a.trim()));
    });
  });
}

async function main() {
  if (process.argv.includes("--help")) {
    console.log(
      fs
        .readFileSync(__filename, "utf8")
        .split("*/")[0]
        .replace(/^[\s\S]*?\/\*\*/, "")
    );
    return;
  }

  const cfg = loadConfig();
  const dryRun = process.argv.includes("--dry-run");
  const force = process.argv.includes("--force");

  console.log(`Proposer (delegate): ${cfg.delegate}`);
  console.log(`Authorizing owner (delegator): ${cfg.delegator}`);
  console.log(`Label: ${cfg.label}`);
  console.log(`Ledger derivation path: ${cfg.hdPath}`);
  console.log(`Auth: ${process.env.SAFE_API_KEY ? "Bearer SAFE_API_KEY" : "unauthenticated"}`);
  console.log(`Safes (${cfg.safes.length}):`);
  cfg.safes.forEach((s) => console.log(`  - ${s}`));
  console.log();

  const chains = await loadChains();

  // Resolve every entry up front so config errors surface before any signing.
  const targets = cfg.safes.map((entry) => {
    const [shortName, rawAddress] = entry.split(":");
    if (!shortName || !rawAddress) throw new Error(`Malformed safe entry "${entry}" (expected shortName:address)`);
    const chain = chains.get(shortName);
    if (!chain) throw new Error(`Unknown chain short-name "${shortName}" (no hosted Safe tx-service)`);
    return { entry, shortName, safe: getAddress(rawAddress), chain };
  });

  if (!dryRun) {
    console.log("Each chain needs a separate on-device Ledger approval (different chainId).");
    const ok = await confirm(`Add ${cfg.delegate} as proposer on ${targets.length} Safe(s)?`);
    if (!ok) {
      console.log("Aborted.");
      return;
    }
    console.log();
  }

  const results: Result[] = [];
  for (const t of targets) {
    const tag = `[${t.chain.chainName} / ${t.shortName}] ${t.safe}`;
    console.log(tag);
    try {
      const owners = await getSafeOwners(t.chain.transactionService, t.safe);
      if (owners === null) {
        console.log("  not indexed by the tx-service");
        if (!force) {
          results.push({ entry: t.entry, chainName: t.chain.chainName, status: "not-indexed" });
          console.log("  SKIP (use --force to attempt anyway)\n");
          continue;
        }
      } else if (!owners.some((o) => getAddress(o) === cfg.delegator)) {
        console.log(`  delegator is not an owner (owners: ${owners.length})`);
        if (!force) {
          results.push({ entry: t.entry, chainName: t.chain.chainName, status: "not-owner" });
          console.log("  SKIP (use --force to attempt anyway)\n");
          continue;
        }
      } else {
        console.log("  delegator confirmed as owner");
      }

      if (await isAlreadyProposer(t.chain.transactionService, t.safe, cfg.delegate)) {
        results.push({ entry: t.entry, chainName: t.chain.chainName, status: "already-proposer" });
        console.log("  already a proposer — nothing to do\n");
        continue;
      }

      if (dryRun) {
        results.push({ entry: t.entry, chainName: t.chain.chainName, status: "would-add" });
        console.log("  would add proposer (dry run)\n");
        continue;
      }

      const signature = signDelegate(t.chain.chainId, cfg.delegate, cfg.delegator, cfg.hdPath);
      await addProposer(t.chain.transactionService, {
        safe: t.safe,
        delegate: cfg.delegate,
        delegator: cfg.delegator,
        label: cfg.label,
        signature,
      });
      results.push({ entry: t.entry, chainName: t.chain.chainName, status: "added" });
      console.log("  proposer added\n");
    } catch (err: any) {
      results.push({ entry: t.entry, chainName: t.chain.chainName, status: "failed", detail: err.message });
      console.log(`  FAILED: ${err.message}\n`);
    }
  }

  console.log("Summary:");
  for (const r of results) {
    console.log(`  ${r.status.padEnd(16)} ${r.entry}${r.detail ? `  (${r.detail})` : ""}`);
  }
  if (results.some((r) => r.status === "failed")) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
