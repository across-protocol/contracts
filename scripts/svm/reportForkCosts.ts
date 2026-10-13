// Offline SVM receipt/account analysis requires TypeScript; Foundry cannot decode these SVM records.
import { strict as assert } from "assert";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import path from "path";
import { gzipSync } from "zlib";
import { PublicKey } from "@solana/web3.js";
import { ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { renderEvidenceReport, executionCuBreakdown, FeeEvidence, Witness } from "./replayForkCosts";
import { TxMeasurement } from "../../test/svm-gateway/fork/recorder";

type Market = { name: string; writable_accounts: string[] };
type Observation = {
  name: string;
  error: string | null;
  samples: { slot: number; prioritizationFee: number }[] | null;
};
type Point = { sample: number; at: string; solUsd?: number; executionRate?: number; globalRate?: number };
type Range = { count: number; min: number; max: number; minAt: Point; maxAt: Point };
const safe = (n: number) => assert(Number.isSafeInteger(n) && n >= 0, "Expected nonnegative safe integer");
// Nearest-rank quantiles; observations are equally weighted polling cycles, not independent slots.
export function distribution(values: number[]) {
  assert(values.length > 0 && values.every((v) => Number.isFinite(v) && v >= 0));
  const sorted = [...values].sort((a, b) => a - b);
  const at = (p: number) => sorted[Math.ceil((p / 100) * sorted.length) - 1];
  return {
    count: sorted.length,
    zeroPercent: (100 * sorted.filter((v) => v === 0).length) / sorted.length,
    min: sorted[0],
    p50: at(50),
    p90: at(90),
    p95: at(95),
    p99: at(99),
    max: sorted[sorted.length - 1],
  };
}
export function writeEvidence(output: string, evidence: unknown) {
  const json = Buffer.from(JSON.stringify(evidence) + "\n");
  const compressed = json.length > 1_000_000;
  const file = compressed ? "fee-evidence.json.gz" : "fee-evidence.json";
  const bytes = compressed ? gzipSync(json, { level: 9 }) : json;
  if (compressed) bytes[9] = 255; // Unknown OS; compression versions may still produce different bytes.
  writeFileSync(path.join(output, file), bytes);
  return {
    file,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    jsonSha256: createHash("sha256").update(json).digest("hex"),
    bytes: bytes.length,
    jsonBytes: json.length,
  };
}
export function priorityLamports(limit: number, rate: number) {
  safe(limit);
  safe(rate);
  const n = Number((BigInt(limit) * BigInt(rate) + 999999n) / 1000000n);
  safe(n);
  return n;
}
export function combinedRate(names: string[], observations: Observation[]): number | null {
  let combined: Map<number, number> | undefined;
  for (const name of names) {
    const o = observations.find((m) => m.name === name);
    if (!o || o.error !== null || !o.samples) return null;
    const slots = new Map<number, number>();
    for (const s of o.samples) {
      safe(s.slot);
      safe(s.prioritizationFee);
      assert(!slots.has(s.slot), "Duplicate priority fee slot");
      slots.set(s.slot, s.prioritizationFee);
    }
    if (slots.size < 25) return null;
    if (!combined) combined = slots;
    else
      for (const [slot, rate] of combined) {
        if (slots.has(slot)) combined.set(slot, Math.max(rate, slots.get(slot)!));
        else combined.delete(slot);
      }
  }
  if (!combined || combined.size < 25) return null;
  const rates = [...combined]
    .sort((a, b) => b[0] - a[0])
    .slice(0, 25)
    .map((s) => s[1])
    .filter((n) => n > 0);
  return rates.length ? Number(rates.reduce((s, n) => s + BigInt(n), 0n) / BigInt(rates.length)) : 0;
}
function add(ranges: Record<string, Range>, key: string, value: number, point: Point) {
  assert(Number.isFinite(value) && value >= 0);
  const r = ranges[key];
  if (!r) ranges[key] = { count: 1, min: value, max: value, minAt: point, maxAt: point };
  else {
    r.count++;
    if (value < r.min) {
      r.min = value;
      r.minAt = point;
    }
    if (value > r.max) {
      r.max = value;
      r.maxAt = point;
    }
  }
}
function fee(tx: TxMeasurement, base: number, rate: number) {
  safe(base);
  safe(tx.signatureCount);
  const total = base * tx.signatureCount + priorityLamports(tx.computeUnitLimit, rate);
  safe(total);
  return total;
}
// Supplement runner diagnostics from confirmed account metadata, including external-fill recipients.
// An ATA being present does not imply every program searches its bump; see the phase inventory.
export function tokenAccountPdas(receipt: any) {
  const keys = [
    ...receipt.transaction.message.staticAccountKeys,
    ...receipt.meta.loadedAddresses.writable,
    ...receipt.meta.loadedAddresses.readonly,
  ];
  return (receipt.meta.preTokenBalances ?? []).flatMap((balance: any) => {
    if (!balance.owner || !balance.programId) return [];
    const [address, bump] = PublicKey.findProgramAddressSync(
      [balance.owner, balance.programId, balance.mint].map((key) => new PublicKey(key).toBuffer()),
      ASSOCIATED_TOKEN_PROGRAM_ID
    );
    return address.toBase58() === keys[balance.accountIndex]
      ? [
          {
            address: address.toBase58(),
            owner: balance.owner,
            mint: balance.mint,
            tokenProgram: balance.programId,
            bump,
            extraAttempts: 255 - bump,
          },
        ]
      : [];
  });
}
export function rentFromReceipts(receipts: any[]) {
  let buffer = 0,
    returned = 0,
    retained = 0,
    lookupTable = 0;
  const buffers = new Set<string>();
  for (const t of receipts) {
    assert.equal(t.receipt.meta.err, null);
    const m = t.receipt.meta;
    const keys = [
      ...t.receipt.transaction.message.staticAccountKeys,
      ...m.loadedAddresses.writable,
      ...m.loadedAddresses.readonly,
    ];
    for (let i = 1; i < keys.length; i++) {
      const before = m.preBalances[i],
        after = m.postBalances[i];
      safe(before);
      safe(after);
      if (t.phase === "buffer-init" && before === 0 && after > 0) {
        buffers.add(keys[i]);
        buffer += after;
      }
      if (t.phase === "execution" && buffers.has(keys[i])) {
        assert.equal(after, 0);
        returned += before;
      }
      if (t.phase === "execution" && before === 0 && after > 0) retained += after;
      if (t.phase === "setup-alt") lookupTable += Math.max(0, after - before);
    }
  }
  assert(buffer > 0 && returned === buffer, "Parameter buffer rent was not fully returned");
  return {
    temporaryBufferLamports: buffer,
    refundedBufferLamports: returned,
    retainedFillStatusLamports: retained,
    lookupTableLamports: lookupTable,
  };
}

export async function report(
  measurements: string,
  archive: string,
  output: string,
  archiveBytes = statSync(archive).size
) {
  assert(!existsSync(output), "Use a fresh report directory");
  safe(archiveBytes);
  assert(archiveBytes > 0 && archiveBytes <= statSync(archive).size);
  const inputs = JSON.parse(readFileSync(path.join(measurements, "fee-inputs.json"), "utf8"));
  const measured = JSON.parse(readFileSync(path.join(measurements, "results.json"), "utf8"));
  assert(measured.completed && inputs.rows.length === measured.rows.length);
  const receiptCache = new Map<number, any[]>();
  const models = inputs.rows.map((row: any) => {
    if (!receiptCache.has(row.sample))
      receiptCache.set(
        row.sample,
        readFileSync(path.join(measurements, `receipts-${row.sample}.jsonl`), "utf8")
          .trim()
          .split("\n")
          .map((s) => JSON.parse(s))
      );
    const receipts = receiptCache.get(row.sample)!.filter((t) => t.flow === row.flow);
    for (const tx of row.transactions) {
      const actual = receipts.find((t) => t.signature === tx.signature);
      assert(actual && actual.computeUnitLimit === tx.computeUnitLimit && actual.signatureCount === tx.signatureCount);
      assert.equal(actual.receipt.meta.computeUnitsConsumed, tx.consumedCu, "Receipt CU differs from measurement");
    }
    const executions = receipts.filter((t) => t.phase === "execution");
    assert.equal(executions.length, 1, "Expected one execution receipt per fixture");
    const execution = executions[0];
    const executionCu = {
      signature: execution.signature as string,
      logMessages: execution.receipt.meta.logMessages as string[],
      ...executionCuBreakdown(execution.receipt.meta.logMessages, execution.receipt.meta.computeUnitsConsumed),
    };
    const markets = [
      ...new Set<string>([
        "global",
        ...row.transactions.filter((t: any) => t.phase === "execution").flatMap((t: any) => t.matchedComponents),
      ]),
    ];
    assert(markets.length > 1, "Execution needs shared-account coverage");
    return {
      flow: row.flow as string,
      sample: row.sample as number,
      executionCu,
      markets,
      transactions: row.transactions as TxMeasurement[],
      setup: receipts.filter((t) => t.phase === "setup-alt") as TxMeasurement[],
      rent: rentFromReceipts(receipts),
      tokenAccountPdas: tokenAccountPdas(receipts.find((t) => t.phase === "execution").receipt),
      pdaSearches: measured.rows.find((r: any) => r.flow === row.flow && r.sample === row.sample)?.pdaSearches,
      lookupTable: measured.rows.find((r: any) => r.flow === row.flow && r.sample === row.sample)?.lookupTable,
    };
  });
  const flows: Record<
    string,
    {
      markets: string[];
      observed: Record<string, Range>;
      baseline: Record<string, Range>;
      rent: Record<string, Range>;
      missingFeeSnapshots: number;
      missingUsdSnapshots: number;
    }
  > = {};
  for (const m of models) {
    flows[m.flow] ??= {
      markets: m.markets,
      observed: {},
      baseline: {},
      rent: {},
      missingFeeSnapshots: 0,
      missingUsdSnapshots: 0,
    };
    assert.deepEqual(flows[m.flow].markets, m.markets, "Shared account sets differ between CU samples");
  }
  let header: any,
    snapshots = 0,
    pricedSnapshots = 0,
    first: number | undefined,
    last: number | undefined;
  let latestPrice: { usd_per_sol: number; fetched_at_ms: number; source: string } | undefined;
  let latestBase: { lamports: number; at: number } | undefined;
  let maxGapMs = 0,
    ended = false;
  const archiveHash = createHash("sha256");
  const prices: Record<string, Range> = {};
  const series = [
    ...new Map<string, string[]>(models.map((m: any) => [m.markets.join(","), m.markets as string[]])).values(),
  ].map((components, i) => ({ id: `execution-${i + 1}`, components }));
  const evidenceRows: (number | null)[][] = [];
  const witnesses = new Map<string, Witness>();
  const requiredMarkets = new Set<string>(models.flatMap((m: any) => m.markets));
  function consume(line: string) {
    const record = JSON.parse(line);
    if (record.kind === "run") {
      assert(
        !header && record.schema_version === 1 && record.estimator === "solana_rpc_latest25_nonzero_mean",
        "Unsupported archive"
      );
      assert.equal(record.genesis_hash, "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d");
      header = record;
      for (const name of new Set<string>(models.flatMap((m: any) => m.markets))) {
        const actual = header.manifest.markets.find((m: Market) => m.name === name);
        const expected = inputs.feeManifest.markets.find((m: Market) => m.name === name);
        assert(actual && expected, `Missing component ${name}`);
        assert.deepEqual(
          [...actual.writable_accounts].sort(),
          [...expected.writable_accounts].sort(),
          `Account set changed: ${name}`
        );
      }
      return;
    }
    if (record.kind === "end") {
      ended = true;
      return;
    }
    assert(header && !ended && record.kind === "snapshot");
    const at = record.finished_at_ms;
    safe(at);
    if (last !== undefined) {
      assert(at >= last);
      maxGapMs = Math.max(maxGapMs, at - last);
    }
    first ??= at;
    last = at;
    snapshots++;
    const price = record.sol_usd;
    const priced =
      price &&
      !record.price_error &&
      Number.isFinite(price.usd_per_sol) &&
      price.usd_per_sol > 0 &&
      price.fetched_at_ms <= at &&
      at - price.fetched_at_ms <= header.options.max_price_age_seconds * 1000;
    if (priced) {
      latestPrice = price;
      pricedSnapshots++;
      add(prices, "solUsd", price.usd_per_sol, { sample: -1, at: new Date(at).toISOString() });
    }
    const base = record.lamports_per_signature;
    const baseOk = base !== null && !record.base_fee_error;
    if (baseOk) {
      safe(base);
      latestBase = { lamports: base, at };
    }
    const rates = new Map<string, number | null>();
    const global = combinedRate(["global"], record.markets);
    for (const [name, flow] of Object.entries(flows)) {
      const key = flow.markets.join(",");
      if (!rates.has(key)) rates.set(key, combinedRate(flow.markets, record.markets));
      const execution = rates.get(key)!;
      if (!baseOk || global === null || execution === null) {
        flow.missingFeeSnapshots++;
        continue;
      }
      if (!priced) flow.missingUsdSnapshots++;
      for (const model of models.filter((m: any) => m.flow === name)) {
        const point = {
          sample: model.sample,
          at: new Date(at).toISOString(),
          executionRate: execution,
          globalRate: global,
          ...(priced ? { solUsd: price.usd_per_sol } : {}),
        };
        const network = model.transactions.reduce(
          (n: number, tx: TxMeasurement) => n + fee(tx, base, tx.phase === "execution" ? execution : global),
          0
        );
        const setup = model.setup.reduce((n: number, tx: TxMeasurement) => n + fee(tx, base, global), 0);
        const values = {
          networkLamports: network,
          outlayLamports: network + model.rent.retainedFillStatusLamports,
          freshLookupTableNetworkLamports: network + setup,
          freshLookupTableOutlayLamports:
            network + setup + model.rent.retainedFillStatusLamports + model.rent.lookupTableLamports,
        };
        add(flow.observed, "executionRate", execution, point);
        add(flow.observed, "auxiliaryRate", global, point);
        for (const [metric, value] of Object.entries(values)) {
          add(flow.observed, metric, value, point);
          if (priced) add(flow.observed, metric.replace("Lamports", "Usd"), (value / 1e9) * price.usd_per_sol, point);
        }
      }
    }
    evidenceRows.push([
      at,
      baseOk ? base : null,
      priced ? price.usd_per_sol : null,
      global,
      ...series.map((s) => rates.get(s.components.join(",")) ?? null),
    ]);
    const extremaTimes = new Set(
      [...Object.values(prices), ...Object.values(flows).flatMap((f) => Object.values(f.observed))].flatMap((r) => [
        r.minAt.at,
        r.maxAt.at,
      ])
    );
    const timestamp = new Date(at).toISOString();
    if (extremaTimes.has(timestamp))
      witnesses.set(timestamp, {
        finishedAtMs: at,
        baseLamportsPerSignature: baseOk ? base : null,
        solUsd: priced ? price : null,
        markets: record.markets
          .filter((m: Observation) => requiredMarkets.has(m.name))
          .map((m: Observation) => ({
            name: m.name,
            failed: m.error !== null,
            // Tuples preserve the complete returned RPC windows without repeating field names.
            samples: m.samples?.map((s) => [s.slot, s.prioritizationFee]) ?? null,
          })),
      });
    for (const key of witnesses.keys()) if (!extremaTimes.has(key)) witnesses.delete(key);
  }
  // Freeze a byte prefix while the collector keeps appending. Ignore only the final unterminated line.
  let pending = "";
  for await (const chunk of createReadStream(archive, { end: archiveBytes - 1 })) {
    archiveHash.update(chunk);
    pending += chunk.toString("utf8");
    let end: number;
    while ((end = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, end);
      pending = pending.slice(end + 1);
      if (line.trim()) consume(line);
    }
  }
  assert(header && snapshots > 0 && latestPrice && latestBase, "No usable snapshot/base-fee/price evidence");
  const baselineRate = 50000;
  const baselineFixtures = models.map((model: any) => {
    const point = {
      sample: model.sample,
      at: new Date(latestPrice!.fetched_at_ms).toISOString(),
      solUsd: latestPrice!.usd_per_sol,
      executionRate: baselineRate,
      globalRate: baselineRate,
    };
    const flow = flows[model.flow];
    const transactions = model.transactions.map((tx: TxMeasurement) => ({
      ...tx,
      baseLamports: latestBase!.lamports * tx.signatureCount,
      priorityLamports: priorityLamports(tx.computeUnitLimit, baselineRate),
      networkLamports: fee(tx, latestBase!.lamports, baselineRate),
    }));
    const network = transactions.reduce((n: number, tx: any) => n + tx.networkLamports, 0);
    const setup = model.setup.reduce(
      (n: number, tx: TxMeasurement) => n + fee(tx, latestBase!.lamports, baselineRate),
      0
    );
    const values = {
      networkLamports: network,
      outlayLamports: network + model.rent.retainedFillStatusLamports,
      freshLookupTableNetworkLamports: network + setup,
      freshLookupTableOutlayLamports:
        network + setup + model.rent.retainedFillStatusLamports + model.rent.lookupTableLamports,
    };
    for (const [metric, value] of Object.entries(values)) {
      add(flow.baseline, metric, value, point);
      add(flow.baseline, metric.replace("Lamports", "Usd"), (value / 1e9) * latestPrice!.usd_per_sol, point);
    }
    for (const [metric, value] of Object.entries(model.rent)) add(flow.rent, metric, value as number, point);
    return { flow: model.flow, sample: model.sample, transactions, setupNetworkLamports: setup, rent: model.rent };
  });
  for (const flow of Object.values(flows)) assert(flow.observed.networkUsd, "No priced observations for a flow");
  const hashes = Object.fromEntries(
    ["results.json", "fee-inputs.json", ...[...receiptCache.keys()].map((n) => `receipts-${n}.jsonl`)].map((f) => [
      f,
      createHash("sha256")
        .update(readFileSync(path.join(measurements, f)))
        .digest("hex"),
    ])
  );
  const distributions = Object.fromEntries(
    Object.entries(flows).map(([name, flow]) => {
      const index = 4 + series.findIndex((s) => s.components.join(",") === flow.markets.join(","));
      const valid = evidenceRows.filter((r) => r[1] !== null && r[3] !== null && r[index] !== null);
      const fixtures = models
        .filter((m: any) => m.flow === name)
        .map((m: any) => {
          const costs = valid.map((r) => ({
            lamports: m.transactions.reduce(
              (sum: number, tx: TxMeasurement) => sum + fee(tx, r[1]!, tx.phase === "execution" ? r[index]! : r[3]!),
              0
            ),
            price: r[2],
          }));
          return {
            sample: m.sample,
            networkSol: distribution(costs.map((c) => c.lamports / 1e9)),
            networkUsd: distribution(costs.filter((c) => c.price !== null).map((c) => (c.lamports / 1e9) * c.price!)),
          };
        });
      return [
        name,
        {
          executionRate: distribution(valid.map((r) => r[index]!)),
          auxiliaryRate: distribution(valid.map((r) => r[3]!)),
          fixtures,
        },
      ];
    })
  );
  const result = {
    schema: 1,
    generatedAt: new Date().toISOString(),
    measurements: path.resolve(measurements),
    inputHashes: hashes,
    reportSourceSha256: createHash("sha256").update(readFileSync(__filename)).digest("hex"),
    archive: {
      path: path.resolve(archive),
      bytes: archiveBytes,
      sha256: archiveHash.digest("hex"),
      ignoredTrailingBytes: Buffer.byteLength(pending),
      runId: header.run_id,
      revision: header.revision,
      estimator: header.estimator,
      manifest: header.manifest,
      snapshots,
      pricedSnapshots,
      first: new Date(first!).toISOString(),
      last: new Date(last!).toISOString(),
      maxGapMs,
      ended,
    },
    baseline: { microLamportsPerCu: baselineRate, baseFee: latestBase, solUsd: latestPrice },
    prices,
    flows,
    baselineFixtures,
    distributions,
    assumptions: [
      "Fixed 50k applies to every transaction; snapshot rates use global for approval/buffer/ALT and global plus matched shared components for execution.",
      "Combine raw rates by common slot maximum, then latest 25 slots, drop zero rates, integer mean; missing observations are not zero.",
      "Observed ranges span all measured CU fixtures and successful snapshot cycles. USD uses the price in the same cycle; baseline USD uses the latest valid archived quote.",
      `Submitted CU limits already include the measured ${measured.provenance.marginBps} bps simulation margin. Round priority fees up separately for every transaction.`,
      "Existing source/recipient ATAs and reusable lookup tables are assumed for primary totals. Fresh-table totals include measured setup fees and locked rent.",
      "Outlay adds retained fill-status rent to network fees. Buffer rent is fully refunded by execution and shown only as temporary capital. Principal transfers, swap slippage/protocol fees, tips, retries and later account-close fees are excluded.",
      "Jussi applies its configured per-chain bid volatility margin to priority rates when bidding; these raw estimates and the fixed 50k scenario exclude that margin. Base signature fees and rent are not multiplied. Zero priority rates remain zero.",
      "Percentiles use nearest rank across cost-eligible polling cycles, with zeros included and missing base/rates excluded; USD additionally requires a valid same-cycle quote. Cost percentiles are calculated per CU fixture, then shown as the range across fixtures. Overlapping slot windows are correlated; percentiles are not landing probabilities.",
      "Shared-account history excludes synthetic/user-specific wallet activity. Historical minima/estimator ranges are observations, not landing guarantees.",
    ],
  };
  mkdirSync(output, { recursive: true });

  const evidence: FeeEvidence = {
    schema: 3,
    units: { rates: "micro-lamports per CU", baseFee: "lamports per signature", price: "USD per SOL" },
    archive: {
      runId: result.archive.runId,
      revision: result.archive.revision,
      bytes: archiveBytes,
      sha256: result.archive.sha256,
      first: result.archive.first,
      last: result.archive.last,
      snapshots,
      ignoredTrailingBytes: result.archive.ignoredTrailingBytes,
      maxGapMs,
      ended,
    },
    measurement: {
      sourceCommit: measured.provenance.spokeArtifact?.sourceCommit,
      ciRun: measured.provenance.spokeArtifact?.ciRun,
      spokeBinarySha256: measured.provenance.spokeBinarySha256,
      snapshotSlot: measured.provenance.snapshotSlot,
      validator: measured.provenance.validator,
      marginBps: measured.provenance.marginBps,
    },
    assumptions: result.assumptions,
    reportSourceSha256: result.reportSourceSha256,
    replaySourceSha256: createHash("sha256")
      .update(readFileSync(path.join(__dirname, "replayForkCosts.ts")))
      .digest("hex"),
    inputHashes: hashes,
    estimator: header.estimator,
    baseline: result.baseline,
    markets: header.manifest.markets.filter((m: Market) => requiredMarkets.has(m.name)),
    series,
    flows: Object.fromEntries(
      Object.entries(flows).map(([name, flow]) => [
        name,
        {
          executionSeries: series.find((s) => s.components.join(",") === flow.markets.join(","))!.id,
          auxiliarySeries: "global",
          missingFeeSnapshots: flow.missingFeeSnapshots,
          missingUsdSnapshots: flow.missingUsdSnapshots,
          executionRange: flow.observed.executionRate,
          auxiliaryRange: flow.observed.auxiliaryRate,
        },
      ])
    ),
    columns: ["finishedAtMs", "baseLamportsPerSignature", "solUsd", "global", ...series.map((s) => s.id)],
    observations: evidenceRows,
    extremaWitnesses: [...witnesses.values()],
    distributions,
    fixtures: models.map((m: any) => ({
      flow: m.flow,
      sample: m.sample,
      rent: m.rent,
      executionCu: m.executionCu,
      pdaSearches: m.pdaSearches,
      tokenAccountPdas: m.tokenAccountPdas,
      lookupTable: m.lookupTable,
      transactions: [...m.transactions, ...m.setup].map((tx: TxMeasurement) => ({
        phase: tx.phase,
        computeUnitLimit: tx.computeUnitLimit,
        signatureCount: tx.signatureCount,
        bytes: tx.bytes,
        consumedCu: tx.consumedCu,
      })),
    })),
    interpretation:
      "Derived observations preserve every collected cycle, including null missing values; ranges count CU fixtures as well as cycles. Witnesses contain the raw RPC windows at the reported rate/cost/price extrema. These selected witnesses cannot independently prove the absence of a larger value elsewhere in the full archive. The archive prefix hash identifies that full local source. No RPC URLs, credentials or local filesystem paths are exported.",
  };
  // Compact tuple arrays keep the review artifact small enough to commit and refresh.
  const evidenceArtifact = writeEvidence(output, evidence);
  writeFileSync(path.join(output, "costs.json"), JSON.stringify({ ...result, evidenceArtifact }, null, 2) + "\n");
  writeFileSync(path.join(output, "costs.md"), await renderEvidenceReport(evidence, evidenceArtifact));
  return result;
}
if (require.main === module) {
  const [measurements, archive, output] = process.argv.slice(2);
  assert(
    measurements && archive && output,
    "Usage: yarn report-svm-fork-costs <CU-run-directory> <snapshots.jsonl> <new-output-directory>"
  );
  report(
    measurements,
    archive,
    output,
    process.env.SVM_COST_ARCHIVE_BYTES ? Number(process.env.SVM_COST_ARCHIVE_BYTES) : undefined
  )
    .then((r) => console.log(`Cost report: ${path.resolve(output)}/costs.md (${r.archive.snapshots} snapshots)`))
    .catch((e) => {
      console.error(e);
      process.exitCode = 1;
    });
}
