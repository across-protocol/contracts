// Portable SVM evidence is replayed offline; no validator, RPC or private archive is needed.
import { strict as assert } from "assert";
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { gunzipSync } from "zlib";
import { format } from "prettier";

type Bounds = { min: number; max: number; count: number };
type Quantiles = Bounds & { zeroPercent: number; p50: number; p90: number; p95: number; p99: number };
type FixtureDistribution = { sample: number; networkSol: Quantiles; networkUsd: Quantiles };
type Distributions = { executionRate: Quantiles; auxiliaryRate: Quantiles; fixtures: FixtureDistribution[] };
type Rent = {
  temporaryBufferLamports: number;
  refundedBufferLamports: number;
  retainedFillStatusLamports: number;
  lookupTableLamports: number;
};
type Quote = { usd_per_sol: number; fetched_at_ms: number; source: string };
export const CU_PROGRAMS = {
  spoke: "DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru",
  raydium: "CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C",
};
type ExecutionCu = { signature: string; logMessages: string[]; spoke: number; raydium: number; other: number };

// Program consumption includes its nested CPIs. Attribute only the outermost
// invocation of each target, so self-CPI event emission is not counted twice.
export function executionCuBreakdown(logs: string[], total: number) {
  assert(Array.isArray(logs) && logs.length > 0, "Missing execution logs");
  assert(Number.isSafeInteger(total) && total > 0, "Invalid execution CU");
  const stack: { program: string; consumed?: number }[] = [];
  const units = { spoke: 0, raydium: 0 };
  for (const line of logs) {
    assert(typeof line === "string" && !line.includes("Log truncated"), "Truncated execution logs");
    assert(!/^Program \S+ failed:/.test(line), "Failed execution logs");
    const invoke = /^Program (\S+) invoke \[(\d+)\]$/.exec(line);
    if (invoke) {
      assert.equal(Number(invoke[2]), stack.length + 1, "Invalid invocation depth");
      stack.push({ program: invoke[1] });
    }
    const consumed = /^Program (\S+) consumed (\d+) of (\d+) compute units$/.exec(line);
    if (consumed) {
      const frame = stack[stack.length - 1];
      assert(frame?.program === consumed[1] && frame.consumed === undefined, "Invalid consumption log");
      frame.consumed = Number(consumed[2]);
      assert(Number.isSafeInteger(frame.consumed) && frame.consumed <= Number(consumed[3]));
    }
    const success = /^Program (\S+) success$/.exec(line);
    if (success) {
      const frame = stack.pop();
      assert(frame?.program === success[1], "Unbalanced execution logs");
      for (const key of ["spoke", "raydium"] as const) {
        if (frame.program !== CU_PROGRAMS[key]) continue;
        assert(frame.consumed !== undefined, "Missing target program consumption");
        assert(
          !stack.some((f) => Object.values(CU_PROGRAMS).includes(f.program) && f.program !== frame.program),
          "Overlapping attributed programs"
        );
        if (!stack.some((f) => f.program === frame.program)) units[key] += frame.consumed;
      }
    }
  }
  assert.equal(stack.length, 0, "Incomplete execution logs");
  assert(units.spoke > 0 && units.spoke + units.raydium <= total, "Invalid attributed execution CU");
  return { ...units, other: total - units.spoke - units.raydium };
}
export type Witness = {
  finishedAtMs: number;
  baseLamportsPerSignature: number | null;
  solUsd: Quote | null;
  markets: { name: string; failed: boolean; samples: number[][] | null }[];
};
export type FeeEvidence = {
  schema: number;
  units: { rates: string; baseFee: string; price: string };
  archive: {
    runId: string;
    revision: string;
    bytes: number;
    sha256: string;
    first: string;
    last: string;
    snapshots: number;
    ignoredTrailingBytes: number;
    maxGapMs: number;
    ended: boolean;
  };
  measurement: {
    sourceCommit?: string;
    ciRun?: number;
    spokeBinarySha256?: string;
    snapshotSlot?: number;
    validator?: string;
    marginBps: number;
  };
  reportSourceSha256: string;
  replaySourceSha256: string;
  inputHashes: Record<string, string>;
  estimator: string;
  baseline: { microLamportsPerCu: number; baseFee: { lamports: number; at: number }; solUsd: Quote };
  markets: { name: string; writable_accounts: string[] }[];
  series: { id: string; components: string[] }[];
  flows: Record<
    string,
    {
      executionSeries: string;
      auxiliarySeries: string;
      missingFeeSnapshots: number;
      missingUsdSnapshots: number;
      executionRange: Bounds;
      auxiliaryRange: Bounds;
    }
  >;
  columns: string[];
  observations: (number | null)[][];
  extremaWitnesses: Witness[];
  distributions: Record<string, Distributions>;
  fixtures: {
    flow: string;
    sample: number;
    executionCu: ExecutionCu;
    rent: Rent;
    pdaSearches?: unknown;
    tokenAccountPdas?: unknown;
    lookupTable?: unknown;
    transactions: {
      phase: string;
      computeUnitLimit: number;
      signatureCount: number;
      bytes: number;
      consumedCu: number;
    }[];
  }[];
  assumptions: string[];
  interpretation: string;
};
type Artifact = { file: string; sha256: string; jsonSha256: string; bytes: number; jsonBytes: number };
const hash = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const integer = (n: number) => assert(Number.isSafeInteger(n) && n >= 0, "Expected nonnegative safe integer");
function quantiles(values: number[]): Quantiles {
  assert(values.length > 0, "No usable observations");
  const a = [...values].sort((x, y) => x - y);
  const rank = (p: number) => a[Math.ceil((p / 100) * a.length) - 1];
  return {
    count: a.length,
    zeroPercent: (100 * a.filter((x) => x === 0).length) / a.length,
    min: a[0],
    p50: rank(50),
    p90: rank(90),
    p95: rank(95),
    p99: rank(99),
    max: a[a.length - 1],
  };
}
function add(bounds: Record<string, Bounds>, key: string, n: number) {
  assert(Number.isFinite(n) && n >= 0);
  const b = bounds[key];
  if (b) {
    b.min = Math.min(b.min, n);
    b.max = Math.max(b.max, n);
    b.count++;
  } else bounds[key] = { min: n, max: n, count: 1 };
}
function sameBounds(actual: Bounds, expected: Bounds) {
  for (const key of ["min", "max", "count"] as const) assert.equal(actual[key], expected[key], `Incorrect ${key}`);
}

// Deliberately independent arithmetic from the archive exporter, so replay checks its summaries.
export function verifyEvidence(e: FeeEvidence) {
  assert.equal(e.schema, 3, "Use schema-3 portable evidence exported with execution logs");
  assert.equal(e.estimator, "solana_rpc_latest25_nonzero_mean");
  assert.deepEqual(e.columns, [
    "finishedAtMs",
    "baseLamportsPerSignature",
    "solUsd",
    "global",
    ...e.series.map((s) => s.id),
  ]);
  assert.equal(new Set(e.columns).size, e.columns.length);
  assert.equal(e.observations.length, e.archive.snapshots);
  assert(e.observations.length > 0 && e.fixtures.length > 0);
  const observations = new Map<number, (number | null)[]>();
  let previous = -1;
  for (const row of e.observations) {
    assert.equal(row.length, e.columns.length);
    row.forEach((v, i) => {
      if (v !== null) {
        assert(Number.isFinite(v) && v >= 0);
        if (i !== 2) integer(v);
      }
    });
    assert(row[0] !== null && (row[2] === null || row[2] > 0));
    assert(!observations.has(row[0]), "Duplicate snapshot timestamp");
    assert(row[0] > previous, "Snapshot timestamps must increase");
    previous = row[0];
    observations.set(row[0], row);
  }
  assert.equal(new Date(e.observations[0][0]!).toISOString(), e.archive.first);
  assert.equal(new Date(e.observations[e.observations.length - 1][0]!).toISOString(), e.archive.last);
  integer(e.baseline.microLamportsPerCu);
  assert.equal(e.baseline.microLamportsPerCu, 50000);
  integer(e.baseline.baseFee.lamports);
  assert(e.baseline.solUsd.usd_per_sol > 0 && Number.isFinite(e.baseline.solUsd.usd_per_sol));
  assert.equal(observations.get(e.baseline.baseFee.at)?.[1], e.baseline.baseFee.lamports);
  assert.equal(e.observations.filter((r) => r[2] !== null).slice(-1)[0]?.[2], e.baseline.solUsd.usd_per_sol);
  assert.equal(new Set(e.fixtures.map((f) => `${f.flow}:${f.sample}`)).size, e.fixtures.length);
  for (const f of e.fixtures) {
    assert(e.flows[f.flow], "Unknown fixture flow");
    Object.values(f.rent).forEach(integer);
    assert.equal(f.rent.temporaryBufferLamports, f.rent.refundedBufferLamports);
    assert.equal(f.transactions.filter((t) => t.phase === "execution").length, 1);
    const execution = f.transactions.find((t) => t.phase === "execution")!;
    const cu = f.executionCu;
    assert(cu && typeof cu.signature === "string" && cu.signature.length > 0, "Missing execution CU witness");
    assert.deepEqual(
      executionCuBreakdown(cu.logMessages, execution.consumedCu),
      { spoke: cu.spoke, raydium: cu.raydium, other: cu.other },
      "Stored CU attribution differs from execution logs"
    );
    for (const t of f.transactions) {
      [t.computeUnitLimit, t.signatureCount, t.bytes, t.consumedCu].forEach(integer);
      assert(t.signatureCount > 0 && t.bytes > 0 && t.bytes <= 1232);
      assert(t.consumedCu > 0 && t.consumedCu <= t.computeUnitLimit && t.computeUnitLimit <= 1_400_000);
    }
  }
  const flows: Record<
    string,
    {
      baseline: Record<string, Bounds>;
      observed: Record<string, Bounds>;
      rent: Record<string, Bounds>;
      missingFeeSnapshots: number;
      missingUsdSnapshots: number;
    }
  > = {};
  const distributions: Record<string, Distributions> = {};
  for (const [name, flow] of Object.entries(e.flows)) {
    const index = e.columns.indexOf(flow.executionSeries);
    assert(index >= 4 && flow.auxiliarySeries === "global");
    const fixtures = e.fixtures.filter((f) => f.flow === name);
    assert(fixtures.length > 0);
    const valid = e.observations.filter((r) => r[1] !== null && r[3] !== null && r[index] !== null);
    const result: (typeof flows)[string] = (flows[name] = {
      baseline: {},
      observed: {},
      rent: {},
      missingFeeSnapshots: e.observations.length - valid.length,
      missingUsdSnapshots: valid.filter((r) => r[2] === null).length,
    });
    assert.equal(result.missingFeeSnapshots, flow.missingFeeSnapshots);
    assert.equal(result.missingUsdSnapshots, flow.missingUsdSnapshots);
    const d = (distributions[name] = {
      executionRate: quantiles(valid.map((r) => r[index]!)),
      auxiliaryRate: quantiles(valid.map((r) => r[3]!)),
      fixtures: [] as FixtureDistribution[],
    });
    for (const mode of ["baseline", "observed"] as const) {
      const rows =
        mode === "observed"
          ? valid
          : [
              [
                e.baseline.solUsd.fetched_at_ms,
                e.baseline.baseFee.lamports,
                e.baseline.solUsd.usd_per_sol,
                ...Array(e.columns.length - 3).fill(e.baseline.microLamportsPerCu),
              ],
            ];
      for (const f of fixtures) {
        const sol: number[] = [],
          usd: number[] = [];
        for (const r of rows) {
          let network = 0,
            setup = 0;
          for (const t of f.transactions) {
            const rate = t.phase === "execution" ? r[index]! : r[3]!;
            const fee =
              r[1]! * t.signatureCount + Number((BigInt(t.computeUnitLimit) * BigInt(rate) + 999999n) / 1000000n);
            integer(fee);
            if (t.phase === "setup-alt") setup += fee;
            else network += fee;
          }
          const metrics = {
            networkLamports: network,
            outlayLamports: network + f.rent.retainedFillStatusLamports,
            freshLookupTableNetworkLamports: network + setup,
            freshLookupTableOutlayLamports:
              network + setup + f.rent.retainedFillStatusLamports + f.rent.lookupTableLamports,
          };
          for (const [key, n] of Object.entries(metrics)) {
            integer(n);
            add(result[mode], key, n);
            if (r[2] !== null) add(result[mode], key.replace("Lamports", "Usd"), (n / 1e9) * r[2]);
          }
          sol.push(network / 1e9);
          if (r[2] !== null) usd.push((network / 1e9) * r[2]);
          if (mode === "observed") {
            add(result.observed, "executionRate", r[index]!);
            add(result.observed, "auxiliaryRate", r[3]!);
          }
        }
        if (mode === "observed")
          d.fixtures.push({ sample: f.sample, networkSol: quantiles(sol), networkUsd: quantiles(usd) });
        else for (const [key, n] of Object.entries(f.rent)) add(result.rent, key, n);
      }
    }
    sameBounds(result.observed.executionRate, flow.executionRange);
    sameBounds(result.observed.auxiliaryRate, flow.auxiliaryRange);
  }
  assert.deepEqual(distributions, e.distributions, "Stored distributions differ from portable observations/fixtures");
  for (const witness of e.extremaWitnesses) {
    const row = observations.get(witness.finishedAtMs);
    assert(row, "Witness is outside the observation window");
    assert.equal(witness.baseLamportsPerSignature, row[1]);
    assert.equal(witness.solUsd?.usd_per_sol ?? null, row[2]);
    for (const series of [{ id: "global", components: ["global"] }, ...e.series]) {
      const markets = series.components.map((name) => witness.markets.find((m) => m.name === name));
      let rate: number | null = null;
      if (markets.every((m) => m && !m.failed && m.samples && m.samples.length >= 25)) {
        const windows = markets.map(
          (m) =>
            new Map(
              m!.samples!.map(([slot, fee]) => {
                integer(slot);
                integer(fee);
                return [slot, fee];
              })
            )
        );
        windows.forEach((w, i) => assert.equal(w.size, markets[i]!.samples!.length));
        const slots = [...windows[0].keys()].filter((s) => windows.every((w) => w.has(s))).sort((a, b) => b - a);
        if (slots.length >= 25) {
          const fees = slots
            .slice(0, 25)
            .map((s) => Math.max(...windows.map((w) => w.get(s)!)))
            .filter((n) => n > 0);
          rate = fees.length ? Number(fees.reduce((sum, n) => sum + BigInt(n), 0n) / BigInt(fees.length)) : 0;
        }
      }
      assert.equal(rate, row[e.columns.indexOf(series.id)], `Raw witness disagrees with ${series.id}`);
    }
  }
  return { flows, distributions };
}

export function loadEvidence(file: string, expectedJsonHash?: string) {
  const bytes = readFileSync(file);
  const json = bytes[0] === 0x1f && bytes[1] === 0x8b ? gunzipSync(bytes) : bytes;
  const artifact = {
    file: path.basename(file),
    sha256: hash(bytes),
    jsonSha256: hash(json),
    bytes: bytes.length,
    jsonBytes: json.length,
  };
  if (expectedJsonHash) assert.equal(artifact.jsonSha256, expectedJsonHash, "Evidence JSON hash mismatch");
  return { evidence: JSON.parse(json.toString("utf8")) as FeeEvidence, artifact };
}

export async function renderEvidenceReport(e: FeeEvidence, artifact: Artifact) {
  const { flows, distributions } = verifyEvidence(e);
  const range = (b: Pick<Bounds, "min" | "max">, scale = 1, digits = 6) => {
    const lo = (b.min / scale).toFixed(digits),
      hi = (b.max / scale).toFixed(digits);
    return lo === hi ? lo : `${lo}–${hi}`;
  };
  const table = (head: string[], rows: (string | number)[][]) =>
    [head, head.map(() => "---"), ...rows].map((r) => `| ${r.join(" | ")} |`).join("\n");
  const names = Object.keys(flows),
    m = e.measurement;
  const sections = [
    "# V5 Spoke CU and SOL/USD cost study",
    `Status: **${e.archive.ended ? "Collection ended" : "Interim — collection in progress at this cutoff"}**. Observation window: **${e.archive.first} – ${e.archive.last}**; ${e.archive.snapshots} snapshots.`,
    "## Provenance and reproduction",
    `- Collector commit: [\`${e.archive.revision}\`](https://github.com/across-protocol/jussi/tree/${e.archive.revision}).\n- Archive prefix: ${e.archive.bytes} bytes; SHA-256 \`${e.archive.sha256}\`.\n- Exporter SHA-256: \`${e.reportSourceSha256}\`.\n- Replay/renderer SHA-256: \`${e.replaySourceSha256}\`.\n- Maximum sampling gap: ${e.archive.maxGapMs / 1000} seconds; ignored trailing bytes: ${e.archive.ignoredTrailingBytes}.`,
    ...(m.sourceCommit
      ? [
          `- Spoke source: \`${m.sourceCommit}\`; [verified CI](https://github.com/across-protocol/contracts/actions/runs/${m.ciRun}).\n- Spoke binary SHA-256: \`${m.spokeBinarySha256}\`.\n- Mainnet snapshot slot: ${m.snapshotSlot}; validator: ${m.validator}.`,
        ]
      : []),
    `Evidence: [${artifact.file}](${artifact.file}). JSON reference SHA-256: \`${artifact.jsonSha256}\` (${artifact.jsonBytes} bytes). Artifact SHA-256: \`${artifact.sha256}\` (${artifact.bytes} bytes).`,
    `From the repository root, regenerate this document with \`yarn replay-svm-fork-costs <evidence.json[.gz]> <report.md>\`; add \`--check\` to verify it without writing. See the [run guide](../README.md) for collection and refresh instructions.`,
    e.interpretation,
    "## Execution CU and packet size",
    `${e.fixtures.length} execution fixtures; ${e.fixtures.reduce((n, f) => n + f.transactions.length, 0)} total transaction receipts. CU extrema are observed samples, not fixed reservation bounds. See the [PDA search model](../README.md#cu-variation-and-transaction-layout).`,
    table(
      ["Flow", "Lowest observed CU", "Highest observed CU", "Execution packet bytes"],
      names.map((name) => {
        const txs = e.fixtures
          .filter((f) => f.flow === name)
          .flatMap((f) => f.transactions.filter((t) => t.phase === "execution"));
        return [
          name,
          Math.min(...txs.map((t) => t.consumedCu)),
          Math.max(...txs.map((t) => t.consumedCu)),
          range({ min: Math.min(...txs.map((t) => t.bytes)), max: Math.max(...txs.map((t) => t.bytes)) }, 1, 0),
        ];
      })
    ),
    "## Execution CU attribution",
    "Computed from the saved execution transaction logs, retained in the portable evidence. Spoke and Raydium figures include their nested CPIs; only outermost invocations are counted, so self-CPI events are not counted twice. Gateway/other is the transaction total minus those two components: Gateway logic, funding/delivery, other calls, CPI dispatch and compute-budget overhead. Approval, buffer and lookup-table transactions are excluded. Ranges span fixtures; independently selected extrema need not add to the same total.",
    table(
      ["Flow", "Total CU", "Spoke CU", "Raydium CU", "Gateway/other CU", "Spoke share %"],
      names.map((name) => {
        const fixtures = e.fixtures.filter((f) => f.flow === name);
        const totals = fixtures.map((f) => f.transactions.find((t) => t.phase === "execution")!.consumedCu);
        const span = (values: number[], digits = 0) =>
          range({ min: Math.min(...values), max: Math.max(...values) }, 1, digits);
        return [
          name,
          span(totals),
          span(fixtures.map((f) => f.executionCu.spoke)),
          span(fixtures.map((f) => f.executionCu.raydium)),
          span(fixtures.map((f) => f.executionCu.other)),
          span(
            fixtures.map((f, i) => (100 * f.executionCu.spoke) / totals[i]),
            1
          ),
        ];
      })
    ),
    "This is compute attribution, not separate program billing or a measurement of the cost saved by removing an adapter. Priority fees use the whole transaction's requested CU limit (including its safety margin) at one rate. A higher rate associated with swap accounts therefore also prices the Spoke and Gateway work at that rate. Compare the fixed-50k cost column with the snapshot ranges to distinguish transaction work from fee-market variation. Base signature fees, auxiliary transactions and rent are separate from these CU shares.",
    ...(names.includes("deposit-cosigned") && names.includes("swap-deposit")
      ? [
          (() => {
            const plain = e.fixtures.filter((f) => f.flow === "deposit-cosigned");
            const swaps = e.fixtures.filter((f) => f.flow === "swap-deposit");
            const ratios = swaps.map((f) => {
              const base = plain.find((p) => p.sample === f.sample)!;
              return (
                f.transactions.find((t) => t.phase === "execution")!.consumedCu /
                base.transactions.find((t) => t.phase === "execution")!.consumedCu
              );
            });
            const peak = Math.max(
              ...names.filter((n) => n.includes("swap")).map((n) => distributions[n].executionRate.max)
            );
            return `In these fixtures, swap→deposit uses ${range({ min: Math.min(...ratios), max: Math.max(...ratios) }, 1, 2)}× the execution CU of a co-signed deposit. The largest swap-associated estimated rate in this window is ${peak.toLocaleString("en-US")} micro-lamports/CU (${(peak / e.baseline.microLamportsPerCu).toFixed(1)}× the fixed 50k baseline). These are distinct compute and rate effects; historical rate estimates do not establish required landing bids.`;
          })(),
        ]
      : []),
    "## Priority-fee distribution",
    "Rates are micro-lamports/CU. Nearest-rank percentiles include zeros and exclude cycles missing base fees or required rates. Counts are overlapping polling cycles, not independent events or landing probabilities.",
    table(
      [
        "Flow",
        "Cycles",
        "Missing fees",
        "Additional missing USD",
        "Zero %",
        "Min",
        "p50",
        "p90",
        "p95",
        "p99",
        "Max",
        "Above 50k",
      ],
      names.map((name) => {
        const f = flows[name],
          d = distributions[name].executionRate,
          index = e.columns.indexOf(e.flows[name].executionSeries);
        const above = e.observations.filter(
          (r) => r[1] !== null && r[3] !== null && r[index] !== null && r[index]! > 50000
        ).length;
        return [
          name,
          d.count,
          f.missingFeeSnapshots,
          f.missingUsdSnapshots,
          d.zeroPercent.toFixed(2),
          d.min,
          d.p50,
          d.p90,
          d.p95,
          d.p99,
          d.max,
          above,
        ];
      })
    ),
    "Approval, buffer and lookup-table setup use the global series. Its cost-eligible range per flow is:",
    table(
      ["Flow", "Global minimum", "Global maximum"],
      names.map((name) => [name, distributions[name].auxiliaryRate.min, distributions[name].auxiliaryRate.max])
    ),
    "## Network-fee percentiles",
    "Cells span per-fixture percentiles. USD uses each cycle's price; base signature fees remain payable at zero priority rate.",
    table(
      ["Flow", "Unit", "p50", "p90", "p95", "p99"],
      names.flatMap((name) =>
        (["networkSol", "networkUsd"] as const).map((unit) => [
          name,
          unit === "networkSol" ? "SOL" : "USD",
          ...(["p50", "p90", "p95", "p99"] as const).map((p) => {
            const values = distributions[name].fixtures.map((f) => f[unit][p]);
            return range({ min: Math.min(...values), max: Math.max(...values) }, 1, unit === "networkSol" ? 9 : 6);
          }),
        ])
      )
    ),
    `Fixed baseline: 50,000 micro-lamports/CU on every transaction; ${e.baseline.baseFee.lamports} lamports/signature; $${e.baseline.solUsd.usd_per_sol}/SOL (${new Date(e.baseline.solUsd.fetched_at_ms).toISOString()}, ${e.baseline.solUsd.source}).`,
    ...(["network", "outlay"] as const).flatMap((metric) => [
      metric === "network"
        ? "## Network fees, including approval and buffer transactions"
        : "## Network fees plus newly locked fill-status rent",
      table(
        ["Flow", "Fixed 50k SOL", "Fixed 50k USD", "Snapshot SOL range", "Snapshot USD range"],
        names.map((name) => {
          const f = flows[name];
          return [
            name,
            range(f.baseline[metric + "Lamports"], 1e9, 9),
            "$" + range(f.baseline[metric + "Usd"]),
            range(f.observed[metric + "Lamports"], 1e9, 9),
            "$" + range(f.observed[metric + "Usd"]),
          ];
        })
      ),
    ]),
    "## Refundable capital and optional setup",
    table(
      [
        "Flow",
        "Temporary buffer SOL (returned)",
        "Fill-status SOL (retained until close)",
        "Fresh lookup table SOL rent",
        "Fresh-table 50k fees + retained rent SOL",
      ],
      names.map((name) => {
        const f = flows[name];
        return [
          name,
          ...[
            f.rent.temporaryBufferLamports,
            f.rent.retainedFillStatusLamports,
            f.rent.lookupTableLamports,
            f.baseline.freshLookupTableOutlayLamports,
          ].map((b) => range(b, 1e9, 9)),
        ];
      })
    ),
    "## Interpretation",
    e.assumptions.map((s) => `- ${s}`).join("\n"),
  ];
  return format(sections.join("\n\n") + "\n", { parser: "markdown" });
}

export async function replayEvidence(file: string, output: string, check = false) {
  assert(path.resolve(file) !== path.resolve(output), "Report must not overwrite evidence");
  const { evidence, artifact } = loadEvidence(file);
  const markdown = await renderEvidenceReport(evidence, artifact);
  if (check) assert.equal(readFileSync(output, "utf8"), markdown, "Published report differs; regenerate from evidence");
  else writeFileSync(output, markdown);
}
if (require.main === module) {
  const [file, output, flag, extra] = process.argv.slice(2);
  assert(
    file && output && !extra && (!flag || flag === "--check"),
    "Usage: yarn replay-svm-fork-costs <evidence.json[.gz]> <report.md> [--check]"
  );
  replayEvidence(file, output, flag === "--check")
    .then(() => console.log(`Verified evidence and ${flag ? "checked" : "wrote"} ${output}`))
    .catch((e) => {
      console.error(e);
      process.exitCode = 1;
    });
}
