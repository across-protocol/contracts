import { strict as assert } from "assert";
import { loadEvidence, verifyEvidence, replayEvidence } from "../../../scripts/svm/replayForkCosts";
import {
  combinedRate,
  distribution,
  tokenAccountPdas,
  writeEvidence,
  priorityLamports,
  rentFromReceipts,
  report,
} from "../../../scripts/svm/reportForkCosts";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { gunzipSync, gzipSync } from "zlib";
import { createHash } from "crypto";
import { PublicKey } from "@solana/web3.js";
import { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { recipient, USDC } from "./config";

describe("Fork cost accounting", () => {
  it("reproduces the committed report from portable evidence without local receipts or RPC access", async () => {
    const dir = path.join(__dirname, "results");
    const files = readdirSync(dir).filter((f) => /-fee-evidence\.json(\.gz)?$/.test(f));
    assert.equal(files.length, 1, "Keep one evidence artifact for this study");
    const file = path.join(dir, files[0]);
    const { evidence } = loadEvidence(file);
    assert.equal(
      evidence.reportSourceSha256,
      createHash("sha256")
        .update(readFileSync(path.resolve(__dirname, "../../../scripts/svm/reportForkCosts.ts")))
        .digest("hex")
    );
    assert.equal(
      evidence.replaySourceSha256,
      createHash("sha256")
        .update(readFileSync(path.resolve(__dirname, "../../../scripts/svm/replayForkCosts.ts")))
        .digest("hex")
    );
    await replayEvidence(file, file.replace(/-fee-evidence\.json(\.gz)?$/, ".md"), true);
  }).timeout(60_000);
  it("derives ATA bumps from confirmed token owners and resolves lookup keys without labelling arbitrary token accounts as ATAs", () => {
    const owner = recipient(2).publicKey;
    const address = getAssociatedTokenAddressSync(USDC, owner).toBase58();
    const receipt = {
      transaction: { message: { staticAccountKeys: [PublicKey.default.toBase58()] } },
      meta: {
        loadedAddresses: { writable: [address], readonly: [] },
        preTokenBalances: [0, 1].map((accountIndex) => ({
          accountIndex,
          owner: owner.toBase58(),
          mint: USDC.toBase58(),
          programId: TOKEN_PROGRAM_ID.toBase58(),
        })),
      },
    };
    assert.deepEqual(tokenAccountPdas(receipt), [
      {
        address,
        owner: owner.toBase58(),
        mint: USDC.toBase58(),
        tokenProgram: TOKEN_PROGRAM_ID.toBase58(),
        bump: 254,
        extraAttempts: 1,
      },
    ]);
  });
  it("uses nearest-rank percentiles including zeros and hashes evidence independently of gzip encoding", () => {
    const rates = distribution([...Array(95).fill(0), 5, 10, 20, 100, 1000]);
    assert.equal(rates.p95, 0);
    assert.equal(rates.p99, 100);
    assert.equal(rates.zeroPercent, 95);
    assert.throws(() => distribution([]));
    const dir = mkdtempSync(path.join(tmpdir(), "fee-evidence-"));
    try {
      const input = {
        observations: Array.from({ length: 30000 }, (_, i) => [i, 5000, 110, 0, 0, 0, 1000000, 1000000]),
      };
      const first = writeEvidence(dir, input);
      assert.equal(first.file, "fee-evidence.json.gz");
      const bytes = readFileSync(path.join(dir, first.file));
      assert.equal(createHash("sha256").update(bytes).digest("hex"), first.sha256);
      assert.equal(bytes[9], 255);
      const json = Buffer.from(JSON.stringify(input) + "\n");
      assert.equal(createHash("sha256").update(json).digest("hex"), first.jsonSha256);
      assert.equal(first.jsonBytes, json.length);
      for (const os of [3, 19, 10]) {
        const platformBytes = Buffer.from(bytes);
        platformBytes[9] = os;
        assert.equal(createHash("sha256").update(gunzipSync(platformBytes)).digest("hex"), first.jsonSha256);
      }
      const otherEncoding = gzipSync(json, { level: 1 });
      assert.notDeepEqual(otherEncoding, bytes);
      assert.equal(createHash("sha256").update(gunzipSync(otherEncoding)).digest("hex"), first.jsonSha256);
      assert.deepEqual(JSON.parse(gunzipSync(bytes).toString()), input);
      assert.deepEqual(writeEvidence(dir, input), first);
      const plain = writeEvidence(dir, { small: true });
      assert.equal(plain.file, "fee-evidence.json");
      assert.equal(plain.jsonSha256, plain.sha256);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it("pairs prices with fee observations and reproduces a frozen archive prefix while it grows", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "fork-costs-"));
    try {
      const measurements = path.join(dir, "cu"),
        archive = path.join(dir, "snapshots.jsonl");
      mkdirSync(measurements);
      const markets = [
        { name: "global", writable_accounts: [] },
        { name: "shared", writable_accounts: ["vault"] },
      ];
      const transactions = [
        {
          phase: "buffer-init",
          signature: "init",
          computeUnitLimit: 1000,
          signatureCount: 1,
          bytes: 100,
          consumedCu: 900,
          matchedComponents: [],
        },
        {
          phase: "execution",
          signature: "execute",
          computeUnitLimit: 100000,
          bytes: 200,
          consumedCu: 90000,
          signatureCount: 1,
          matchedComponents: ["shared"],
        },
      ];
      const row = { flow: "fixture", sample: 0, transactions };
      const write = (name: string, value: unknown) =>
        writeFileSync(path.join(measurements, name), JSON.stringify(value));
      write("results.json", { completed: true, rows: [row], provenance: { marginBps: 1000 } });
      write("fee-inputs.json", { rows: [row], feeManifest: { markets } });
      const receipts = transactions.map((t, i) => ({
        ...t,
        flow: "fixture",
        receipt: {
          transaction: { message: { staticAccountKeys: ["payer", "buffer"] } },
          meta: {
            err: null,
            loadedAddresses: { writable: [], readonly: [] },
            preBalances: i ? [85000, 10000] : [100000, 0],
            postBalances: i ? [90000, 0] : [85000, 10000],
          },
        },
      }));
      writeFileSync(
        path.join(measurements, "receipts-0.jsonl"),
        receipts.map((r) => JSON.stringify(r)).join("\n") + "\n"
      );
      const header = {
        kind: "run",
        schema_version: 1,
        estimator: "solana_rpc_latest25_nonzero_mean",
        genesis_hash: "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d",
        manifest: { markets },
        options: { max_price_age_seconds: 120 },
      };
      const snapshot = (at: number, rate: number, price: number) => ({
        kind: "snapshot",
        finished_at_ms: at,
        lamports_per_signature: 5000,
        base_fee_error: null,
        price_error: null,
        sol_usd: { usd_per_sol: price, fetched_at_ms: at, source: "fixture" },
        markets: markets.map((m) => ({
          name: m.name,
          error: null,
          samples: Array.from({ length: 25 }, (_, slot) => ({
            slot,
            prioritizationFee: m.name === "global" ? 0 : rate,
          })),
        })),
      });
      const failed = snapshot(3000, 0, 200);
      const records = [
        header,
        snapshot(1000, 10000000, 100),
        snapshot(2000, 0, 200),
        { ...failed, markets: [failed.markets[0]] },
        { ...snapshot(4000, 0, 200), price_error: "unavailable" },
      ];
      const prefix = records.map((r) => JSON.stringify(r)).join("\n") + '\n{"kind":';
      writeFileSync(archive, prefix);
      const first = await report(measurements, archive, path.join(dir, "first"));
      const flow = first.flows.fixture;
      assert.equal(flow.missingFeeSnapshots, 1);
      assert.equal(flow.missingUsdSnapshots, 1);
      assert.equal(flow.observed.networkLamports.min, 10000);
      assert.equal(flow.observed.networkLamports.max, 1010000);
      assert.equal(flow.observed.networkUsd.min, 0.002);
      assert.equal(flow.observed.networkUsd.max, 0.101); // High fee paired with $100, not $200.
      assert.equal(flow.baseline.networkLamports.min, 15050);
      assert.equal(first.archive.ignoredTrailingBytes, 8);
      const d = first.distributions.fixture;
      assert.equal(d.executionRate.count, 3);
      assert.equal(d.executionRate.zeroPercent, 200 / 3);
      assert.equal(d.fixtures[0].networkUsd.p50, 0.002);
      assert.equal(d.fixtures[0].networkUsd.p99, 0.101);
      const evidence = JSON.parse(readFileSync(path.join(dir, "first/fee-evidence.json"), "utf8"));
      assert.deepEqual(evidence.observations, [
        [1000, 5000, 100, 0, 10000000],
        [2000, 5000, 200, 0, 0],
        [3000, 5000, 200, 0, null],
        [4000, 5000, null, 0, 0],
      ]);
      assert.equal(evidence.flows.fixture.executionSeries, "execution-1");
      assert.equal(evidence.fixtures[0].transactions[1].computeUnitLimit, 100000);
      for (const witness of evidence.extremaWitnesses) {
        const observations = witness.markets.map((m: any) => ({
          name: m.name,
          error: m.failed ? "failed" : null,
          samples: m.samples?.map(([slot, prioritizationFee]: number[]) => ({ slot, prioritizationFee })) ?? null,
        }));
        const derived = evidence.observations.find((r: number[]) => r[0] === witness.finishedAtMs);
        assert.equal(combinedRate(evidence.series[0].components, observations), derived[4]);
      }
      assert(!JSON.stringify(evidence).includes(dir), "Review evidence must not contain local paths");
      const verified = verifyEvidence(evidence);
      for (const mode of ["baseline", "observed", "rent"] as const)
        for (const [key, bounds] of Object.entries(verified.flows.fixture[mode])) {
          assert.equal(bounds.min, flow[mode][key].min);
          assert.equal(bounds.max, flow[mode][key].max);
          assert.equal(bounds.count, flow[mode][key].count);
        }
      const copy = () => JSON.parse(JSON.stringify(evidence));
      const badSummary = copy();
      badSummary.distributions.fixture.executionRate.p99++;
      assert.throws(() => verifyEvidence(badSummary), /Stored distributions/);
      const badWitness = copy();
      badWitness.extremaWitnesses[0].markets[1].samples[0][1]++;
      // Change every nonzero slot so integer averaging cannot conceal the mutation.
      badWitness.extremaWitnesses[0].markets[1].samples.forEach((s: number[]) => (s[1] += 1000000));
      assert.throws(() => verifyEvidence(badWitness), /Raw witness disagrees/);
      const badOrder = copy();
      badOrder.observations.reverse();
      assert.throws(() => verifyEvidence(badOrder), /timestamps must increase/);
      const json = readFileSync(path.join(dir, "first/fee-evidence.json"));
      const compressed = path.join(dir, "evidence.json.gz"),
        markdown = path.join(dir, "report.md");
      writeFileSync(compressed, gzipSync(json));
      assert.deepEqual(loadEvidence(compressed, createHash("sha256").update(json).digest("hex")).evidence, evidence);
      assert.throws(() => loadEvidence(compressed, "wrong"), /hash mismatch/);
      await replayEvidence(compressed, markdown);
      await replayEvidence(compressed, markdown, true);
      appendFileSync(markdown, "stale manual edit\n");
      await assert.rejects(replayEvidence(compressed, markdown, true), /Published report differs/);
      writeFileSync(compressed, gzipSync(json).subarray(0, 16));
      assert.throws(() => loadEvidence(compressed));
      appendFileSync(archive, '"snapshot"}\n');
      const replay = await report(measurements, archive, path.join(dir, "replay"), Buffer.byteLength(prefix));
      assert.deepEqual(replay.flows, first.flows);
      assert.equal(replay.archive.sha256, first.archive.sha256);
      assert.deepEqual(JSON.parse(readFileSync(path.join(dir, "replay/fee-evidence.json"), "utf8")), evidence);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it("charges requested CU and rounds each transaction independently", () => {
    assert.equal(priorityLamports(71925, 50000), 3597);
    assert.equal(priorityLamports(1, 1) + priorityLamports(1, 1), 2);
    assert.equal(priorityLamports(2, 1), 1);
    assert.throws(() => priorityLamports(1, -1));
  });
  it("combines matching slots before estimating instead of taking the maximum of averages", () => {
    const obs = (name: string, rate: (slot: number) => number) => ({
      name,
      error: null,
      samples: Array.from({ length: 30 }, (_, slot) => ({ slot, prioritizationFee: rate(slot) })),
    });
    const a = obs("a", (s) => (s % 2 ? 100 : 1)),
      b = obs("b", (s) => (s % 2 ? 1 : 100));
    assert.equal(combinedRate(["a", "b"], [a, b]), 100);
    assert(combinedRate(["a"], [a])! < 100 && combinedRate(["b"], [b])! < 100);
    assert.equal(combinedRate(["zero"], [obs("zero", () => 0)]), 0);
    assert.equal(combinedRate(["old"], [obs("old", (s) => (s < 5 ? 999999 : 0))]), 0);
    assert.equal(combinedRate(["missing"], [a]), null);
    assert.equal(combinedRate(["a"], [{ ...a, error: "RPC failed" }]), null);
    assert.equal(combinedRate(["a", "b"], [a, { ...b, samples: b.samples.slice(10) }]), null);
    assert.throws(() => combinedRate(["a"], [{ ...a, samples: [...a.samples, a.samples[0]] }]));
  });
  it("separates returned buffer rent, retained status rent and lookup table rent from payer fees", () => {
    const tx = (phase: string, keys: string[], pre: number[], post: number[]) => ({
      phase,
      receipt: {
        transaction: { message: { staticAccountKeys: keys } },
        meta: { err: null, loadedAddresses: { writable: [], readonly: [] }, preBalances: pre, postBalances: post },
      },
    });
    const receipts = [
      tx("buffer-init", ["payer", "buffer"], [100000, 0], [85000, 10000]),
      tx("setup-alt", ["payer", "table"], [85000, 0], [78000, 2000]),
      tx("setup-alt", ["payer", "table"], [78000, 2000], [72000, 3000]),
      tx("execution", ["payer", "buffer", "status", "float"], [72000, 10000, 0, 9000], [77000, 0, 1200, 7800]),
    ];
    assert.deepEqual(rentFromReceipts(receipts), {
      temporaryBufferLamports: 10000,
      refundedBufferLamports: 10000,
      retainedFillStatusLamports: 1200,
      lookupTableLamports: 3000,
    });
    assert.throws(() => rentFromReceipts(receipts.slice(0, -1)));
  });
});
