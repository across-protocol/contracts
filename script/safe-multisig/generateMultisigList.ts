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

const COUNTERFACTUAL_FACTORY_NAMES = ["CounterfactualDepositFactory", "CounterfactualDepositFactoryTron"];

// Deployable contracts under contracts/periphery/mintburn (sponsored CCTP and sponsored OFT flows).
// Used for the chain-qualification filter; includes both Ownable and AccessControl variants.
const SPONSORED_MINTBURN_NAMES = [
  "SponsoredCCTPSrcPeriphery",
  "SponsoredCctpSrcPeriphery",
  "SponsoredCCTPDstPeriphery",
  "SponsoredOFTSrcPeriphery",
  "DstOFTHandler",
];

// Only the sponsored *Src* peripheries are Ownable; the Dst handlers use AccessControl and don't expose owner().
const SPONSORED_CCTP_OWNABLE_NAMES = ["SponsoredCCTPSrcPeriphery", "SponsoredCctpSrcPeriphery"];
const SPONSORED_OFT_OWNABLE_NAMES = ["SponsoredOFTSrcPeriphery"];

// DonationBox variants use AccessControl, so "ownership" = DEFAULT_ADMIN_ROLE membership.
const DONATION_BOX_NAMES = ["DonationBox", "DonationBox_CCTP", "DonationBox_OFT"];
const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";

const OWNABLE_ABI = ["function owner() view returns (address)"];
const AWM_ABI = ["function owner() view returns (address)", "function directWithdrawer() view returns (address)"];
const ACCESS_CONTROL_ABI = ["function hasRole(bytes32 role, address account) view returns (bool)"];

// GitHub renders LaTeX inline in markdown tables; this gives true colored text without needing emoji.
const GREEN_YES = "$\\color{green}\\textsf{Yes}$";
const RED_NO = "$\\color{red}\\textsf{No}$";

type SpokePoolType = "universal" | "native" | "none";

interface DonationBoxInstance {
  name: string;
  address: string;
}

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
  sponsoredCctpAddress?: string;
  sponsoredCctpOwner?: string;
  sponsoredCctpError?: string;
  sponsoredOftAddress?: string;
  sponsoredOftOwner?: string;
  sponsoredOftError?: string;
  donationBoxes: DonationBoxInstance[];
  donationBoxSafeIsAdmin?: boolean;
  donationBoxError?: string;
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

const MAX_RPC_ATTEMPTS = 3; // initial attempt + 2 retries
const RPC_RETRY_BACKOFF_MS = 300;

async function withRetry<T>(label: string, fn: () => Promise<T>): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= MAX_RPC_ATTEMPTS; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt < MAX_RPC_ATTEMPTS) {
        const delay = RPC_RETRY_BACKOFF_MS * attempt;
        // eslint-disable-next-line no-console
        console.warn(
          `  ↻ retry ${attempt}/${MAX_RPC_ATTEMPTS - 1} for ${label} after ${delay}ms (${(err as Error).message ?? err})`
        );
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }
  throw lastErr;
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

async function fetchHasDefaultAdminRole(
  provider: ethers.providers.Provider,
  address: string,
  account: string
): Promise<boolean> {
  const contract = new ethers.Contract(address, ACCESS_CONTROL_ABI, provider);
  return contract.hasRole(DEFAULT_ADMIN_ROLE, account);
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

function findContractAddress(contracts: Record<string, any>, names: readonly string[]): string | undefined {
  for (const name of names) {
    if (contracts[name]?.address) return safeChecksum(contracts[name].address);
  }
  return undefined;
}

function findAllContractInstances(contracts: Record<string, any>, names: readonly string[]): DonationBoxInstance[] {
  const out: DonationBoxInstance[] = [];
  for (const name of names) {
    const addr = contracts[name]?.address;
    if (addr) out.push({ name, address: safeChecksum(addr) as string });
  }
  return out;
}

async function buildEntry(chainId: number, info: { chain_name?: string; contracts?: any }): Promise<ChainEntry> {
  const contracts = info.contracts ?? {};
  const spokePoolAddress = safeChecksum(contracts.SpokePool?.address);
  const adminWithdrawManagerAddress = safeChecksum(contracts.AdminWithdrawManager?.address);
  const sponsoredCctpAddress = findContractAddress(contracts, SPONSORED_CCTP_OWNABLE_NAMES);
  const sponsoredOftAddress = findContractAddress(contracts, SPONSORED_OFT_OWNABLE_NAMES);
  const donationBoxes = findAllContractInstances(contracts, DONATION_BOX_NAMES);
  const safeAddress = readSafeAddress(chainId);
  const spokePoolType = detectSpokePoolType(chainId, spokePoolAddress);

  const entry: ChainEntry = {
    chainId,
    chainName: info.chain_name ?? `Chain ${chainId}`,
    spokePoolAddress,
    spokePoolType,
    safeAddress,
    adminWithdrawManagerAddress,
    sponsoredCctpAddress,
    sponsoredOftAddress,
    donationBoxes,
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
    if (sponsoredCctpAddress) entry.sponsoredCctpError = msg;
    if (sponsoredOftAddress) entry.sponsoredOftError = msg;
    if (donationBoxes.length > 0) entry.donationBoxError = msg;
    return entry;
  }

  const tasks: Promise<unknown>[] = [];

  if (spokePoolType === "universal" && spokePoolAddress) {
    tasks.push(
      withRetry(`chain ${chainId} Universal_SpokePool.owner()`, () => fetchOwner(provider, spokePoolAddress))
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
      withRetry(`chain ${chainId} AdminWithdrawManager state`, () =>
        fetchAwmState(provider, adminWithdrawManagerAddress)
      )
        .then((state) => {
          entry.awmOwner = state.owner;
          entry.awmDirectWithdrawer = state.directWithdrawer;
        })
        .catch((err: Error) => {
          entry.awmError = err.message;
        })
    );
  }

  if (sponsoredCctpAddress) {
    tasks.push(
      withRetry(`chain ${chainId} SponsoredCCTPSrcPeriphery.owner()`, () => fetchOwner(provider, sponsoredCctpAddress))
        .then((owner) => {
          entry.sponsoredCctpOwner = owner;
        })
        .catch((err: Error) => {
          entry.sponsoredCctpError = err.message;
        })
    );
  }

  if (sponsoredOftAddress) {
    tasks.push(
      withRetry(`chain ${chainId} SponsoredOFTSrcPeriphery.owner()`, () => fetchOwner(provider, sponsoredOftAddress))
        .then((owner) => {
          entry.sponsoredOftOwner = owner;
        })
        .catch((err: Error) => {
          entry.sponsoredOftError = err.message;
        })
    );
  }

  if (donationBoxes.length > 0 && safeAddress) {
    tasks.push(
      Promise.all(
        donationBoxes.map((b) =>
          withRetry(`chain ${chainId} ${b.name}.hasRole(DEFAULT_ADMIN_ROLE, safe)`, () =>
            fetchHasDefaultAdminRole(provider, b.address, safeAddress)
          )
        )
      )
        .then((results) => {
          entry.donationBoxSafeIsAdmin = results.every(Boolean);
        })
        .catch((err: Error) => {
          entry.donationBoxError = err.message;
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

// Returns a colored Yes/No (or "—") for a column whose underlying check is "does <contract>.owner match the Safe?"
// - deployed=false → "—" (contract not deployed on this chain)
// - deployed=true, error → "?"
// - deployed=true, no Safe → "—" (no Safe yet, nothing to migrate to)
// - actual missing for any other reason → "—"
// - addresses equal → green Yes
// - addresses differ → red No
function ownershipCell(
  deployed: boolean,
  actual: string | undefined,
  safe: string | undefined,
  error: string | undefined
): string {
  if (!deployed) return "—";
  if (error) return "?";
  if (!actual) return "—";
  if (!safe) return "—";
  return eqAddr(actual, safe) ? GREEN_YES : RED_NO;
}

// AccessControl flavour: cell is Yes if the Safe has DEFAULT_ADMIN_ROLE on the deployed contract(s).
function adminRoleCell(
  deployed: boolean,
  safeIsAdmin: boolean | undefined,
  safe: string | undefined,
  error: string | undefined
): string {
  if (!deployed) return "—";
  if (!safe) return "—";
  if (error) return "?";
  if (safeIsAdmin === undefined) return "—";
  return safeIsAdmin ? GREEN_YES : RED_NO;
}

function collectErrors(entry: ChainEntry): { check: string; message: string }[] {
  const out: { check: string; message: string }[] = [];
  if (entry.universalOwnerError) out.push({ check: "Universal SpokePool owner()", message: entry.universalOwnerError });
  if (entry.awmError) out.push({ check: "AdminWithdrawManager owner()/directWithdrawer()", message: entry.awmError });
  if (entry.sponsoredCctpError)
    out.push({ check: "SponsoredCCTPSrcPeriphery owner()", message: entry.sponsoredCctpError });
  if (entry.sponsoredOftError)
    out.push({ check: "SponsoredOFTSrcPeriphery owner()", message: entry.sponsoredOftError });
  if (entry.donationBoxError)
    out.push({ check: "DonationBox hasRole(DEFAULT_ADMIN_ROLE)", message: entry.donationBoxError });
  return out;
}

function escapeCellText(input: string): string {
  return input.replace(/\|/g, "\\|").replace(/\n+/g, " ");
}

function renderMarkdown(entries: ChainEntry[]): string {
  type Row = { chainId: number; chainName: string; migration: string[] };
  const rows: Row[] = [];

  for (const entry of entries) {
    const isNonEvm = Boolean(entry.skippedNonEvm);
    const safeDeployedCell = entry.safeAddress ? GREEN_YES : RED_NO;

    const universalDeployed = entry.spokePoolType === "universal";
    const universalCell =
      isNonEvm && universalDeployed
        ? "—"
        : ownershipCell(universalDeployed, entry.universalOwner, entry.safeAddress, entry.universalOwnerError);

    const awmDeployed = Boolean(entry.adminWithdrawManagerAddress);
    const awmOwnerCell =
      isNonEvm && awmDeployed ? "—" : ownershipCell(awmDeployed, entry.awmOwner, entry.safeAddress, entry.awmError);
    const awmDwCell =
      isNonEvm && awmDeployed
        ? "—"
        : ownershipCell(awmDeployed, entry.awmDirectWithdrawer, entry.safeAddress, entry.awmError);

    const cctpDeployed = Boolean(entry.sponsoredCctpAddress);
    const cctpCell =
      isNonEvm && cctpDeployed
        ? "—"
        : ownershipCell(cctpDeployed, entry.sponsoredCctpOwner, entry.safeAddress, entry.sponsoredCctpError);

    const oftDeployed = Boolean(entry.sponsoredOftAddress);
    const oftCell =
      isNonEvm && oftDeployed
        ? "—"
        : ownershipCell(oftDeployed, entry.sponsoredOftOwner, entry.safeAddress, entry.sponsoredOftError);

    const donationBoxDeployed = entry.donationBoxes.length > 0;
    const donationBoxCell =
      isNonEvm && donationBoxDeployed
        ? "—"
        : adminRoleCell(donationBoxDeployed, entry.donationBoxSafeIsAdmin, entry.safeAddress, entry.donationBoxError);

    rows.push({
      chainId: entry.chainId,
      chainName: entry.chainName,
      migration: [safeDeployedCell, universalCell, awmOwnerCell, awmDwCell, cctpCell, oftCell, donationBoxCell],
    });
  }

  let yesCount = 0;
  let noCount = 0;
  for (const row of rows) {
    for (const cell of row.migration) {
      if (cell === GREEN_YES) yesCount += 1;
      else if (cell === RED_NO) noCount += 1;
    }
  }
  const decided = yesCount + noCount;
  const pct = decided === 0 ? 0 : (yesCount / decided) * 100;
  const pctLabel = `${pct.toFixed(1)}%`;
  const progressLine = `**Migration progress: ${pctLabel}** — ${yesCount} of ${decided} checks pass${
    noCount > 0 ? ` (${noCount} outstanding)` : ""
  }.`;

  const lines: string[] = [];
  lines.push("# Safe Multisig Migration Status");
  lines.push("");
  lines.push(progressLine);
  lines.push("");
  lines.push(
    "| Chain ID | Chain | Safe Deployed | Safe owns Universal Spoke Pool | Counterfactual WithdrawManager owner | Counterfactual WithdrawManager directWithdrawer | Sponsored CCTP Periphery owner | Sponsored OFT Periphery owner | DonationBox admin |"
  );
  lines.push("| --- | --- | --- | --- | --- | --- | --- | --- | --- |");
  for (const row of rows) {
    lines.push(`| ${row.chainId} | ${row.chainName} | ${row.migration.join(" | ")} |`);
  }
  lines.push("");

  const errorRows: { chainId: number; chainName: string; check: string; message: string }[] = [];
  for (const entry of entries) {
    for (const err of collectErrors(entry)) {
      errorRows.push({ chainId: entry.chainId, chainName: entry.chainName, check: err.check, message: err.message });
    }
  }
  lines.push("## Errors from last run");
  lines.push("");
  if (errorRows.length === 0) {
    lines.push("_No RPC errors during the last run._");
  } else {
    lines.push("| Chain ID | Chain | Check | Error |");
    lines.push("| --- | --- | --- | --- |");
    for (const e of errorRows) {
      lines.push(`| ${e.chainId} | ${e.chainName} | ${e.check} | ${escapeCellText(e.message)} |`);
    }
  }
  lines.push("");
  lines.push("---");
  lines.push("");
  lines.push("Generated by `script/safe-multisig/generateMultisigList.ts`.");
  lines.push("");
  lines.push("Includes only chains that have at least one of:");
  lines.push("- a `CounterfactualDepositFactory` (or `CounterfactualDepositFactoryTron`) deployment");
  lines.push("- a `Universal_SpokePool` deployment");
  lines.push("- a sponsored mintburn deployment from `contracts/periphery/mintburn/` (sponsored CCTP / OFT)");
  lines.push("");
  lines.push("For each qualifying chain it reports:");
  lines.push("- whether the chain's Safe is deployed (`broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`)");
  lines.push("- whether the Safe is the `owner()` of the chain's `Universal_SpokePool` (if any)");
  lines.push(
    "- whether the Safe is the `owner()` and `directWithdrawer()` of the chain's `AdminWithdrawManager` (Counterfactual WithdrawManager)"
  );
  lines.push(
    "- whether the Safe is the `owner()` of the chain's Ownable sponsored mintburn peripheries (`SponsoredCCTPSrcPeriphery`, `SponsoredOFTSrcPeriphery`)"
  );
  lines.push(
    "- whether the Safe holds `DEFAULT_ADMIN_ROLE` on every deployed `DonationBox` variant (DonationBox uses AccessControl, not Ownable)"
  );
  lines.push("");
  lines.push(
    "Status legend: green **Yes** = check passes (Safe is the owner / admin); red **No** = check fails; `—` = not applicable (contract not deployed, or no Safe to compare against)."
  );
  lines.push("");
  lines.push(
    "A `?` in any cell means the on-chain call for that check failed after retries — see the **Errors from last run** section above for the underlying error."
  );
  lines.push("");
  lines.push("The `Migration progress` percentage is `Yes / (Yes + No)` across every cell in the migration columns.");
  lines.push("");
  return lines.join("\n");
}

function chainQualifies(chainId: number, contracts: Record<string, unknown>, spokePoolType: SpokePoolType): boolean {
  if (spokePoolType === "universal") return true;
  if (COUNTERFACTUAL_FACTORY_NAMES.some((name) => contracts[name])) return true;
  if (SPONSORED_MINTBURN_NAMES.some((name) => contracts[name])) return true;
  return false;
}

async function main() {
  if (process.argv.includes("--help")) {
    console.log(`Usage: yarn ts-node ./script/safe-multisig/generateMultisigList.ts [--output <path>]

Filters broadcast/deployed-addresses.json to chains that have at least one of:
- a CounterfactualDepositFactory (or CounterfactualDepositFactoryTron) deployment
- a Universal_SpokePool deployment (broadcast/DeployUniversalSpokePool.s.sol or Tron variant)
- a sponsored mintburn deployment (Sponsored{CCTP,OFT}{Src,Dst}Periphery / DstOFTHandler)

For each qualifying chain:
- looks up the deployed Safe in broadcast/DeploySafe.s.sol/<chainId>/run-latest.json
- if the SpokePool is a Universal_SpokePool, calls owner() to check Safe migration
- if AdminWithdrawManager is deployed, calls owner() and directWithdrawer() to check Safe migration
- if SponsoredCCTPSrcPeriphery or SponsoredOFTSrcPeriphery is deployed, calls owner() to check Safe migration
- if any DonationBox variant is deployed, calls hasRole(DEFAULT_ADMIN_ROLE, safe) to check Safe migration

Failed RPC checks render as \`?\` in the affected cell; full error details are listed in the "Errors from last run" section below the table.

Renders a markdown table prefixed with an overall "Migration progress" percentage computed from the Yes/No cells.

Each RPC call is retried up to 2 times on failure (3 total attempts) with a short backoff before the error is recorded.

Writes the result as a markdown table. Defaults output to script/safe-multisig/MULTISIGS.md.

Env vars: NODE_URL_<chainId> or CUSTOM_NODE_URL provide the RPC. Falls back to PUBLIC_NETWORKS publicRPC.
`);
    return;
  }

  const outputPath = path.resolve(getArg("--output") ?? DEFAULT_OUTPUT_PATH);
  const deployed = loadJson(DEPLOYED_ADDRESSES_PATH);
  const chainIds = Object.keys(deployed.chains)
    .map(Number)
    .filter((cid) => {
      if (!Number.isInteger(cid)) return false;
      const info = deployed.chains[String(cid)];
      const contracts = info?.contracts ?? {};
      const spokePoolAddress = contracts.SpokePool?.address;
      const spokePoolType = detectSpokePoolType(cid, spokePoolAddress);
      return chainQualifies(cid, contracts, spokePoolType);
    })
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
