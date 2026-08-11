/**
 * Shared TronScan verification machinery, used by `tron-verify-stack.ts` (core stack) and
 * `tron-verify-counterfactual-stack.ts` (counterfactual stack). The split mirrors `deploy.ts`,
 * which both deploy scripts import: this module holds everything except the contract table, so
 * each entrypoint is just a `StackContract[]` plus a `runVerification` call.
 *
 * Prerequisites (both entrypoints):
 *   - `bin/solc-tron` (derives the compiler string TronScan expects; override with the
 *     TRON_COMPILER env var, e.g. "tron_v0.8.25+commit.77bd169f")
 *   - `out-tron/` built from the SAME sources/toolchain as the deployment
 *     (`FOUNDRY_PROFILE=tron forge build`)
 */

import "dotenv/config";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { resolveChainId, TRON_MAINNET_CHAIN_ID } from "./deploy";

// TronScan API hosts (mainnet env "online_usa", Nile env "nile").
export const API_BASES: Record<string, string> = {
  [TRON_MAINNET_CHAIN_ID]: "https://apilist.tronscanapi.com",
  "3448148188": "https://nileapi.tronscan.org",
};

// TronScan license ids mirror Etherscan's list.
export const LICENSE_MIT = "3";
export const LICENSE_BUSL = "14";

// Must mirror [profile.tron] (which inherits optimizer/via-IR from [profile.default]).
export const EVM_VERSION = "cancun";
export const VIA_IR = "1";

const REPO_ROOT = path.resolve(__dirname, "../..");

export interface StackContract {
  /** Broadcast artifact name: broadcast/TronDeploy<broadcast>.s.sol/<chainId>/run-latest.json */
  broadcast: string;
  /** Contract name TronScan compiles and matches. */
  contract: string;
  /** Repo-relative source path handed to `forge flatten`. */
  source: string;
  license: string;
}

/** "tron_v0.8.25+commit.77bd169f" — the compiler id TronScan expects. */
export function compilerString(): string {
  if (process.env.TRON_COMPILER) return process.env.TRON_COMPILER;
  const solcTron = path.join(REPO_ROOT, "bin/solc-tron");
  if (!fs.existsSync(solcTron)) {
    console.log("Error: bin/solc-tron not found (needed to derive the compiler string).");
    console.log("Download it per script/tron/README.md, or set TRON_COMPILER=tron_v<ver>+commit.<hash>.");
    process.exit(1);
  }
  const out = execFileSync(solcTron, ["--version"], { encoding: "utf-8" });
  const m = out.match(/Version: ([0-9.]+\+commit\.[0-9a-f]+)/);
  if (!m) {
    console.log(`Error: could not parse solc-tron version output:\n${out}`);
    process.exit(1);
  }
  return `tron_v${m[1]}`;
}

/** Optimizer runs from foundry.toml ([profile.tron] inherits [profile.default]'s value). */
export function optimizerRuns(): string {
  const toml = fs.readFileSync(path.join(REPO_ROOT, "foundry.toml"), "utf-8");
  const m = toml.match(/optimizer_runs\s*=\s*(\d+)/);
  if (!m) {
    console.log("Error: optimizer_runs not found in foundry.toml.");
    process.exit(1);
  }
  return m[1];
}

/** Flatten `source` and normalize every pragma to the closure floor. */
export function flatten(source: string): string {
  const flat = execFileSync("forge", ["flatten", source], {
    cwd: REPO_ROOT,
    encoding: "utf-8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return flat.replace(/pragma solidity [^;]+;/g, "pragma solidity ^0.8.25;");
}

/** Deployed address + ABI-encoded constructor args, recovered from the broadcast artifact. */
export function readDeployment(
  entry: StackContract,
  chainId: string
): { address: string; argsHex: string } | undefined {
  const broadcastFile = path.join(
    REPO_ROOT,
    "broadcast",
    `TronDeploy${entry.broadcast}.s.sol`,
    chainId,
    "run-latest.json"
  );
  if (!fs.existsSync(broadcastFile)) return undefined;
  const tx = JSON.parse(fs.readFileSync(broadcastFile, "utf-8")).transactions?.[0];
  const address: string | undefined = tx?.contractAddress;
  const input: string | undefined = tx?.transaction?.input;
  if (!address || !input) {
    console.log(`Error: malformed broadcast artifact ${broadcastFile}`);
    process.exit(1);
  }

  const artifactFile = path.join(REPO_ROOT, "out-tron", `${entry.contract}.sol`, `${entry.contract}.json`);
  if (!fs.existsSync(artifactFile)) {
    console.log(`Error: ${artifactFile} missing — run FOUNDRY_PROFILE=tron forge build first.`);
    process.exit(1);
  }
  const artifact = JSON.parse(fs.readFileSync(artifactFile, "utf-8"));
  const bytecode: string = (artifact.bytecode?.object || artifact.bytecode).replace(/^0x/, "").toLowerCase();
  const initcode = input.replace(/^0x/, "").toLowerCase();
  if (!initcode.startsWith(bytecode)) {
    console.log(`Error: out-tron bytecode for ${entry.contract} is not a prefix of the deployed initcode.`);
    console.log("The local build differs from what was deployed — rebuild out-tron with the deploy-time");
    console.log("sources and bin/solc-tron (not vanilla solc) before verifying.");
    process.exit(1);
  }
  return { address, argsHex: initcode.slice(bytecode.length) };
}

/** True if TronScan already has verified source for the address. */
export async function isVerified(apiBase: string, address: string): Promise<boolean> {
  try {
    const res = await fetch(`${apiBase}/api/solidity/contract/info`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ contractAddress: address }),
    });
    const body: any = await res.json();
    return Boolean(body?.data?.compiler || body?.compiler);
  } catch {
    return false;
  }
}

export async function verify(
  apiBase: string,
  entry: StackContract,
  address: string,
  argsHex: string,
  source: string,
  compiler: string,
  runs: string
): Promise<boolean> {
  const form = new FormData();
  form.append("contractAddress", address);
  form.append("contractName", entry.contract);
  form.append("compiler", compiler);
  form.append("optimizer", "1");
  form.append("runs", runs);
  form.append("evmVersion", EVM_VERSION);
  form.append("viaIR", VIA_IR);
  form.append("license", entry.license);
  if (argsHex.length > 0) form.append("constructorArguments", argsHex);
  form.append("files", new Blob([source], { type: "text/plain" }), `${entry.contract}.sol`);

  const res = await fetch(`${apiBase}/api/solidity/contract/verify`, { method: "POST", body: form });
  const body: any = await res.json().catch(() => undefined);
  const ok = res.status === 200 && body?.code === 200 && body?.data?.status === 2006;
  console.log(`  ${ok ? "Verified" : "FAILED"}: ${JSON.stringify(body ?? { httpStatus: res.status })}`);
  return ok;
}

/**
 * Verify every entry in `stack` that has a broadcast artifact for the resolved chain. Reads
 * `--dry-run` and positional broadcast names from argv, exactly like the entrypoints did before
 * this was factored out. Exits non-zero if any submission failed.
 */
export async function runVerification(stack: StackContract[], title: string): Promise<void> {
  const flags = process.argv.slice(2);
  const dryRun = flags.includes("--dry-run");
  const only = flags.filter((a) => !a.startsWith("-"));
  const chainId = resolveChainId();
  const apiBase = API_BASES[chainId];

  const compiler = compilerString();
  const runs = optimizerRuns();
  console.log(`=== TronScan ${title} verification ===`);
  console.log(`Chain ID:  ${chainId}`);
  console.log(`API:       ${apiBase}`);
  console.log(`Compiler:  ${compiler}`);
  console.log(`Settings:  optimizer=1 runs=${runs} evmVersion=${EVM_VERSION} viaIR=${VIA_IR}`);
  if (dryRun) console.log("Dry run: nothing will be submitted.");

  const failed: string[] = [];
  let attempted = 0;
  for (const entry of stack) {
    if (only.length > 0 && !only.includes(entry.broadcast)) continue;
    const deployment = readDeployment(entry, chainId);
    if (!deployment) {
      console.log(`\n--- ${entry.broadcast}: no broadcast artifact for chain ${chainId}, skipping ---`);
      continue;
    }
    const { address, argsHex } = deployment;
    console.log(`\n--- ${entry.contract} @ ${address} ---`);
    if (argsHex) console.log(`  Constructor args: ${argsHex}`);

    if (!dryRun && (await isVerified(apiBase, address))) {
      console.log("  Already verified, skipping.");
      continue;
    }

    const source = flatten(entry.source);
    attempted++;
    if (dryRun) {
      console.log(`  Would submit ${entry.contract}.sol (${source.length} bytes flattened, license=${entry.license}).`);
      continue;
    }
    const ok = await verify(apiBase, entry, address, argsHex, source, compiler, runs);
    if (!ok) failed.push(entry.contract);
    // Be polite to the API between submissions.
    await new Promise((r) => setTimeout(r, 2000));
  }

  if (failed.length > 0) {
    console.log(`\n${failed.length}/${attempted} verifications failed: ${failed.join(", ")}`);
    process.exit(1);
  }
  console.log("\nDone.");
}
