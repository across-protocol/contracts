#!/usr/bin/env ts-node

import "dotenv/config";
import * as fs from "fs";
import * as path from "path";
import { getAddress } from "ethers/lib/utils";
import { ethers } from "../../utils/utils";
import { getNodeUrl, CHAIN_IDs, TESTNET_CHAIN_IDs, PUBLIC_NETWORKS } from "../../utils";

const REPO_ROOT = path.resolve(__dirname, "../..");
const BROADCAST_DIR = path.join(REPO_ROOT, "broadcast");
const DEPLOYED_ADDRESSES_PATH = path.join(BROADCAST_DIR, "deployed-addresses.json");
const SAFE_BROADCAST_DIR = path.join(BROADCAST_DIR, "DeploySafe.s.sol");
const UNIVERSAL_BROADCAST_DIR = path.join(BROADCAST_DIR, "DeployUniversalSpokePool.s.sol");
const TRON_UNIVERSAL_BROADCAST_DIR = path.join(BROADCAST_DIR, "TronDeployUniversal_SpokePool.s.sol");
const PROD_READINESS_PATH = path.join(REPO_ROOT, "script/mintburn/prod-readiness-multisigs.json");
const DEFAULT_OUTPUT_PATH = path.resolve(__dirname, "MULTISIGS.md");

const NON_EVM_CHAIN_IDS = new Set<number>([
  728126428, // TRON — needs TronWeb, not JsonRpcProvider
]);

// Testnets (and Scroll, Solana) are excluded from the migration report entirely.
const EXCLUDED_CHAIN_IDS = new Set<number>([...Object.values(TESTNET_CHAIN_IDs), CHAIN_IDs.SCROLL, CHAIN_IDs.SOLANA]);

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
// Matched by prefix because instances carry a bridge/token suffix (e.g. DonationBox_CCTP_USDC, DonationBox_OFT_USDT).
const DONATION_BOX_NAME_PREFIX = "DonationBox";
const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";

const OWNABLE_ABI = ["function owner() view returns (address)"];
const AWM_ABI = ["function owner() view returns (address)", "function directWithdrawer() view returns (address)"];
const ACCESS_CONTROL_ABI = ["function hasRole(bytes32 role, address account) view returns (bool)"];

// Status is conveyed with a colored dot rather than colored text: GitHub renders neither LaTeX math nor
// inline HTML color inside a markdown link, but a leading emoji + a normal link renders everywhere and lets
// each address cell stay clickable. Plain link text also matches the size of the Chain / Chain ID columns.
const GREEN_DOT = "🟢";
const RED_DOT = "🔴";

// Base block-explorer URL for a chain, if known.
function explorerBaseFor(chainId: number): string | undefined {
  const net = (PUBLIC_NETWORKS as Record<number, { blockExplorer?: string }>)[chainId];
  return net?.blockExplorer || undefined;
}

function explorerAddressUrl(base: string, addr: string): string {
  return `${base.replace(/\/+$/, "")}/address/${addr}`;
}

// A rendered table cell. `address`, when set, is the on-chain address the cell refers to and gets a block-explorer link.
type CellKind = "na" | "error" | "yes" | "red";
interface Cell {
  kind: CellKind;
  text?: string;
  address?: string;
}

const NA_CELL: Cell = { kind: "na" };
const ERROR_CELL: Cell = { kind: "error" };

function renderCell(cell: Cell, explorer: string | undefined): string {
  if (cell.kind === "na") return "—";
  if (cell.kind === "error") return "?";
  const dot = cell.kind === "yes" ? GREEN_DOT : RED_DOT;
  const label = cell.address && explorer ? `[${cell.text}](${explorerAddressUrl(explorer, cell.address)})` : cell.text;
  return `${dot} ${label}`;
}

function abbreviateAddress(addr: string): string {
  if (/^0x[0-9a-fA-F]+$/.test(addr) && addr.length > 10) {
    return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
  }
  if (addr.length > 8) {
    return `${addr.slice(0, 4)}…${addr.slice(-4)}`;
  }
  return addr;
}

interface ProdReadinessConfig {
  legacyByChainId: Map<number, string>;
  fallbackEOA: string;
}

function loadProdReadiness(): ProdReadinessConfig {
  const raw = JSON.parse(fs.readFileSync(PROD_READINESS_PATH, "utf8")) as Record<string, string>;
  const legacyByChainId = new Map<number, string>();
  let fallbackEOA = "";
  for (const [key, value] of Object.entries(raw)) {
    if (key === "fallbackEOA") {
      fallbackEOA = getAddress(value);
      continue;
    }
    const cid = Number(key);
    if (Number.isInteger(cid) && cid > 0) {
      legacyByChainId.set(cid, getAddress(value));
    }
  }
  if (!fallbackEOA) throw new Error(`${PROD_READINESS_PATH} is missing a "fallbackEOA" entry`);
  return { legacyByChainId, fallbackEOA };
}

type SpokePoolType = "universal" | "native" | "none";

interface DonationBoxInstance {
  name: string;
  address: string;
}

interface DonationBoxRoleState {
  name: string;
  address: string;
  safeHasRole?: boolean;
  legacyHasRole?: boolean;
  fallbackHasRole?: boolean;
}

interface ChainEntry {
  chainId: number;
  chainName: string;
  spokePoolAddress?: string;
  spokePoolType: SpokePoolType;
  safeAddress?: string;
  legacyMultisig?: string;
  fallbackEOA: string;
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
  donationBoxStates?: DonationBoxRoleState[];
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

// Collects every deployed contract whose name starts with `prefix` (e.g. all DonationBox_* variants), sorted for stable output.
function findContractInstancesByPrefix(contracts: Record<string, any>, prefix: string): DonationBoxInstance[] {
  return Object.keys(contracts)
    .filter((name) => name.startsWith(prefix) && contracts[name]?.address)
    .sort()
    .map((name) => ({ name, address: safeChecksum(contracts[name].address) as string }));
}

async function buildEntry(
  chainId: number,
  info: { chain_name?: string; contracts?: any },
  prodReadiness: ProdReadinessConfig
): Promise<ChainEntry> {
  const contracts = info.contracts ?? {};
  const spokePoolAddress = safeChecksum(contracts.SpokePool?.address);
  const adminWithdrawManagerAddress = safeChecksum(contracts.AdminWithdrawManager?.address);
  const sponsoredCctpAddress = findContractAddress(contracts, SPONSORED_CCTP_OWNABLE_NAMES);
  const sponsoredOftAddress = findContractAddress(contracts, SPONSORED_OFT_OWNABLE_NAMES);
  const donationBoxes = findContractInstancesByPrefix(contracts, DONATION_BOX_NAME_PREFIX);
  const safeAddress = readSafeAddress(chainId);
  const spokePoolType = detectSpokePoolType(chainId, spokePoolAddress);
  const legacyMultisig = prodReadiness.legacyByChainId.get(chainId);
  const fallbackEOA = prodReadiness.fallbackEOA;

  const entry: ChainEntry = {
    chainId,
    chainName: info.chain_name ?? `Chain ${chainId}`,
    spokePoolAddress,
    spokePoolType,
    safeAddress,
    legacyMultisig,
    fallbackEOA,
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
      (async () => {
        try {
          const states: DonationBoxRoleState[] = await Promise.all(
            donationBoxes.map(async (b) => {
              const state: DonationBoxRoleState = { name: b.name, address: b.address };
              const candidates: { key: keyof DonationBoxRoleState; account: string | undefined; label: string }[] = [
                { key: "safeHasRole", account: safeAddress, label: "safe" },
                { key: "legacyHasRole", account: legacyMultisig, label: "legacy" },
                { key: "fallbackHasRole", account: fallbackEOA, label: "fallback" },
              ];
              await Promise.all(
                candidates.map(async (cand) => {
                  if (!cand.account) return;
                  const result = await withRetry(
                    `chain ${chainId} ${b.name}.hasRole(DEFAULT_ADMIN_ROLE, ${cand.label})`,
                    () => fetchHasDefaultAdminRole(provider, b.address, cand.account as string)
                  );
                  (state as any)[cand.key] = result;
                })
              );
              return state;
            })
          );
          entry.donationBoxStates = states;
        } catch (err: any) {
          entry.donationBoxError = err?.message ?? String(err);
        }
      })()
    );
  }

  await Promise.all(tasks);
  return entry;
}

function eqAddr(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  return a.toLowerCase() === b.toLowerCase();
}

// Cell content for an Ownable-style check ("does <contract>.owner() match the Safe?"):
// - deployed=false → "—"
// - error → "?"
// - actual missing or no Safe to compare against → "—"
// - actual === safe → green "Ops multisig"
// - actual === legacy multisig for this chain → red "Legacy multisig"
// - actual === fallback EOA → red "fallbackEOA"
// - otherwise → red abbreviated address
// In every non-trivial case the cell carries the underlying address so it can be linked to the block explorer.
function ownershipCell(
  deployed: boolean,
  actual: string | undefined,
  safe: string | undefined,
  legacy: string | undefined,
  fallback: string | undefined,
  error: string | undefined
): Cell {
  if (!deployed) return NA_CELL;
  if (error) return ERROR_CELL;
  if (!actual) return NA_CELL;
  if (!safe) return NA_CELL;
  if (eqAddr(actual, safe)) return { kind: "yes", text: "Ops multisig", address: actual };
  if (legacy && eqAddr(actual, legacy)) return { kind: "red", text: "Legacy multisig", address: actual };
  if (fallback && eqAddr(actual, fallback)) return { kind: "red", text: "fallbackEOA", address: actual };
  return { kind: "red", text: abbreviateAddress(actual), address: actual };
}

// AccessControl flavour for a single DonationBox: which known candidate (if any) holds DEFAULT_ADMIN_ROLE.
// Safe → green "Ops multisig"; else legacy multisig or fallback EOA → red; else red "No" (held by some
// other address or renounced — AccessControl exposes no getter to resolve who, so there's no address to link).
function donationBoxState(
  s: DonationBoxRoleState,
  safe: string,
  legacy: string | undefined,
  fallback: string | undefined
): Cell {
  if (s.safeHasRole) return { kind: "yes", text: "Ops multisig", address: safe };
  if (legacy && s.legacyHasRole) return { kind: "red", text: "Legacy multisig", address: legacy };
  if (s.fallbackHasRole) return { kind: "red", text: "fallbackEOA", address: fallback };
  return { kind: "red", text: "No" };
}

interface DonationBoxColumn {
  rendered: string; // markdown for the cell: one line per box, joined with <br>
  countable: Cell[]; // per-box cells that feed the migration percentage
}

// Renders the DonationBox Admin column. Chains with several boxes (e.g. CCTP + OFT) list one line per box —
// "<dot> <box>: <holder>" — and each box counts as its own check. NA/error states render a single "—"/"?".
function donationBoxColumn(
  states: DonationBoxRoleState[] | undefined,
  hasDeployments: boolean,
  isNonEvm: boolean,
  safe: string | undefined,
  legacy: string | undefined,
  fallback: string | undefined,
  error: string | undefined,
  explorer: string | undefined
): DonationBoxColumn {
  if (!hasDeployments || !safe || isNonEvm) return { rendered: "—", countable: [] };
  if (error) return { rendered: "?", countable: [] };
  if (!states || states.length === 0) return { rendered: "—", countable: [] };
  const parts = states.map((s) => {
    const cell = donationBoxState(s, safe, legacy, fallback);
    const boxLabel = s.name.replace(/^DonationBox_?/, "") || s.name; // e.g. DonationBox_CCTP_USDC → CCTP_USDC
    const dot = cell.kind === "yes" ? GREEN_DOT : RED_DOT;
    const holder =
      cell.address && explorer ? `[${cell.text}](${explorerAddressUrl(explorer, cell.address)})` : cell.text;
    return { cell, line: `${dot} ${boxLabel}: ${holder}` };
  });
  return { rendered: parts.map((p) => p.line).join("<br>"), countable: parts.map((p) => p.cell) };
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

  let yesCount = 0;
  let noCount = 0;

  for (const entry of entries) {
    const isNonEvm = Boolean(entry.skippedNonEvm);
    const legacy = entry.legacyMultisig;
    const fallback = entry.fallbackEOA;
    const safe = entry.safeAddress;
    // Only EVM chains get explorer links; non-EVM addresses are stored in a hex format their explorers don't accept.
    const explorer = isNonEvm ? undefined : explorerBaseFor(entry.chainId);

    // Non-EVM chains can't be probed over JSON-RPC, so any deployed-but-unprobed contract renders as N/A.
    const ownership = (deployed: boolean, actual: string | undefined, error: string | undefined): Cell =>
      isNonEvm && deployed ? NA_CELL : ownershipCell(deployed, actual, safe, legacy, fallback, error);

    const safeDeployedCell: Cell = safe ? { kind: "yes", text: "Yes", address: safe } : { kind: "red", text: "No" };
    const universalCell = ownership(
      entry.spokePoolType === "universal",
      entry.universalOwner,
      entry.universalOwnerError
    );
    const awmDeployed = Boolean(entry.adminWithdrawManagerAddress);
    const awmOwnerCell = ownership(awmDeployed, entry.awmOwner, entry.awmError);
    const awmDwCell = ownership(awmDeployed, entry.awmDirectWithdrawer, entry.awmError);
    const cctpCell = ownership(Boolean(entry.sponsoredCctpAddress), entry.sponsoredCctpOwner, entry.sponsoredCctpError);
    const oftCell = ownership(Boolean(entry.sponsoredOftAddress), entry.sponsoredOftOwner, entry.sponsoredOftError);

    const ownershipCells = [universalCell, awmOwnerCell, awmDwCell, cctpCell, oftCell];
    const donationBoxes = donationBoxColumn(
      entry.donationBoxStates,
      entry.donationBoxes.length > 0,
      isNonEvm,
      safe,
      legacy,
      fallback,
      entry.donationBoxError,
      explorer
    );

    // Migration progress measures ownership/admin transfer only; whether the Ops multisig (Safe) is deployed
    // (safeDeployedCell) is excluded. Each DonationBox variant counts as its own check.
    for (const cell of [...ownershipCells, ...donationBoxes.countable]) {
      if (cell.kind === "yes") yesCount += 1;
      else if (cell.kind === "red") noCount += 1;
    }

    rows.push({
      chainId: entry.chainId,
      chainName: entry.chainName,
      migration: [
        renderCell(safeDeployedCell, explorer),
        ...ownershipCells.map((cell) => renderCell(cell, explorer)),
        donationBoxes.rendered,
      ],
    });
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
    "| Chain ID | Chain | Ops Multisig Deployed | Universal SpokePool Owner | Counterfactual WithdrawManager Owner | Counterfactual WithdrawManager directWithdrawer | Sponsored CCTP Periphery Owner | Sponsored OFT Periphery Owner | DonationBox Admin |"
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
  lines.push("Testnets (per `TESTNET_CHAIN_IDs`), Scroll, and Solana are excluded.");
  lines.push("");
  lines.push("Throughout this document, **Ops multisig** refers to the chain's new operations Safe");
  lines.push("(from `broadcast/DeploySafe.s.sol/<chainId>/run-latest.json`).");
  lines.push("");
  lines.push("For each qualifying chain the table reports:");
  lines.push(
    "- **Ops Multisig Deployed** — 🟢 `Yes` / 🔴 `No` for whether the chain's Ops multisig (Safe) is deployed"
  );
  lines.push("- **Universal SpokePool Owner** — the on-chain `owner()` of the chain's `Universal_SpokePool` (if any)");
  lines.push(
    "- **Counterfactual WithdrawManager Owner / directWithdrawer** — the on-chain `owner()` and `directWithdrawer()` of the chain's `AdminWithdrawManager`"
  );
  lines.push(
    "- **Sponsored CCTP / OFT Periphery Owner** — the on-chain `owner()` of the chain's Ownable sponsored mintburn peripheries (`SponsoredCCTPSrcPeriphery`, `SponsoredOFTSrcPeriphery`)"
  );
  lines.push(
    "- **DonationBox Admin** — who holds `DEFAULT_ADMIN_ROLE` on each deployed `DonationBox` variant (DonationBox uses AccessControl, not Ownable). Chains with multiple boxes (e.g. CCTP + OFT) list one line per box, and each box counts as its own check"
  );
  lines.push("");
  lines.push(
    "Cell labels (🟢 = migrated / good, 🔴 = outstanding; the label after the dot links to that address on the chain's block explorer):"
  );
  lines.push(
    "- 🟢 `Yes` / 🟢 `Ops multisig` — the chain's Ops multisig (Safe) is deployed / is the owner / admin (migration complete)"
  );
  lines.push(
    "- 🔴 `Legacy multisig` — the chain's pre-migration multisig is still the owner (from `script/mintburn/prod-readiness-multisigs.json`)"
  );
  lines.push("- 🔴 `fallbackEOA` — the shared fallback EOA from the same config is the owner");
  lines.push("- 🔴 `0xABCD…WXYZ` — some other address is the owner (abbreviated)");
  lines.push("- 🔴 `No` — for boolean checks (`Ops Multisig Deployed`, `DonationBox Admin`) when no candidate matches");
  lines.push("- `—` — not applicable (contract not deployed, or no Ops multisig yet to compare against)");
  lines.push("");
  lines.push(
    "A `?` in any cell means the on-chain call for that check failed after retries — see the **Errors from last run** section above for the underlying error."
  );
  lines.push("");
  lines.push(
    "The `Migration progress` percentage is `(🟢 cells) / (🟢 cells + 🔴 cells)` across the ownership/admin columns. The `Ops Multisig Deployed` column is excluded from the count."
  );
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
- for each deployed DonationBox variant, calls hasRole(DEFAULT_ADMIN_ROLE, ...) to check Safe migration (one line + one check per box)

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
  const prodReadiness = loadProdReadiness();
  const chainIds = Object.keys(deployed.chains)
    .map(Number)
    .filter((cid) => {
      if (!Number.isInteger(cid)) return false;
      if (EXCLUDED_CHAIN_IDS.has(cid)) return false;
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
      const entry = await buildEntry(cid, deployed.chains[String(cid)], prodReadiness);
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
