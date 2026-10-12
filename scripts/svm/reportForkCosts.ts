// Offline SVM receipt/account analysis requires TypeScript; Foundry cannot decode these SVM records.
import { strict as assert } from "assert";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import path from "path";
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
    }
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
      markets,
      transactions: row.transactions as TxMeasurement[],
      setup: receipts.filter((t) => t.phase === "setup-alt") as TxMeasurement[],
      rent: rentFromReceipts(receipts),
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
    assumptions: [
      "Fixed 50k applies to every transaction; snapshot rates use global for approval/buffer/ALT and global plus matched shared components for execution.",
      "Combine raw rates by common slot maximum, then latest 25 slots, drop zero rates, integer mean; missing observations are not zero.",
      "Observed ranges span all measured CU fixtures and successful snapshot cycles. USD uses the price in the same cycle; baseline USD uses the latest valid archived quote.",
      `Submitted CU limits already include the measured ${measured.provenance.marginBps} bps simulation margin. Round priority fees up separately for every transaction.`,
      "Existing source/recipient ATAs and reusable lookup tables are assumed for primary totals. Fresh-table totals include measured setup fees and locked rent.",
      "Outlay adds retained fill-status rent to network fees. Buffer rent is fully refunded by execution and shown only as temporary capital. Principal transfers, swap slippage/protocol fees, tips, retries and later account-close fees are excluded.",
      "Shared-account history excludes synthetic/user-specific wallet activity. Historical minima/estimator ranges are observations, not landing guarantees.",
    ],
  };
  mkdirSync(output, { recursive: true });
  writeFileSync(path.join(output, "costs.json"), JSON.stringify(result, null, 2) + "\n");
  const fmt = (r: Range, divisor: number, digits: number) => {
    const lo = (r.min / divisor).toFixed(digits),
      hi = (r.max / divisor).toFixed(digits);
    return lo === hi ? lo : `${lo}–${hi}`;
  };
  const table = (metric: "network" | "outlay") =>
    [
      "| Flow | Fixed 50k SOL | Fixed 50k USD | Snapshot SOL range | Snapshot USD range |",
      "|---|---:|---:|---:|---:|",
      ...Object.entries(flows).map(
        ([name, f]) =>
          `| ${name} | ${fmt(f.baseline[metric + "Lamports"], 1e9, 9)} | $${fmt(f.baseline[metric + "Usd"], 1, 6)} | ${fmt(f.observed[metric + "Lamports"], 1e9, 9)} | $${fmt(f.observed[metric + "Usd"], 1, 6)} |`
      ),
    ].join("\n");
  const md = `# V5 flow SOL/USD costs\n\nArchive: ${result.archive.first} – ${result.archive.last}; ${snapshots} complete snapshots.\nBaseline price: $${latestPrice.usd_per_sol}/SOL (${new Date(latestPrice.fetched_at_ms).toISOString()}, ${latestPrice.source}); base fee ${latestBase.lamports} lamports/signature.\n\n## Network fees, including approval and buffer transactions\n\n${table("network")}\n\n## Network fees plus newly locked fill-status rent\n\n${table("outlay")}\n\n## Refundable capital and optional setup\n\n| Flow | Temporary buffer SOL (returned) | Fill-status SOL (retained until close) | Fresh lookup table SOL rent | Fresh-table 50k fees + retained rent SOL |\n|---|---:|---:|---:|---:|\n${Object.entries(
    flows
  )
    .map(
      ([n, f]) =>
        `| ${n} | ${fmt(f.rent.temporaryBufferLamports, 1e9, 9)} | ${fmt(f.rent.retainedFillStatusLamports, 1e9, 9)} | ${fmt(f.rent.lookupTableLamports, 1e9, 9)} | ${fmt(f.baseline.freshLookupTableOutlayLamports, 1e9, 9)} |`
    )
    .join(
      "\n"
    )}\n\n## Interpretation\n\n${result.assumptions.map((s) => `- ${s}`).join("\n")}\n\nSee costs.json for per-transaction baseline costs, exact extrema timestamps/sample IDs, component mappings, missing observations, optional setup costs in SOL/USD and input hashes.\n`;
  writeFileSync(path.join(output, "costs.md"), md);
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
