// Solana account-snapshot replay requires Agave; Foundry cannot execute SVM programs.
import { strict as assert } from "assert";
import { spawnSync } from "child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "fs";
import path from "path";
import { Connection, PublicKey } from "@solana/web3.js";
import { withLocalValidator } from "./localValidator";
import { captureSnapshot, readSnapshot, genesis, sha256, Snapshot } from "./forkSnapshot";
import { SPOKE, GATEWAY, FEATURES, LOADER, payer, CASES, Flow } from "../../test/svm-gateway/fork/config";
import { resolveSpokeArtifact } from "./forkArtifacts";
import { measure } from "../../test/svm-gateway/fork/measure";
const root = path.resolve(__dirname, "../..");
function run(command: string, args: string[], cwd = root, env = process.env) {
  const r = spawnSync(command, args, { cwd, env, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (r.error) throw r.error;
  if (r.status !== 0) throw new Error(`${command} failed: ${r.stderr}`);
  return r.stdout.trim();
}
async function features(connection: Connection) {
  return (await connection.getProgramAccounts(FEATURES))
    .filter((a) => a.account.data[0] === 1)
    .map((a) => a.pubkey.toBase58())
    .sort();
}
async function verifyPrograms(connection: Connection, snapshot: Snapshot) {
  for (const [address, expected] of Object.entries(snapshot.programs)) {
    const info = await connection.getAccountInfo(new PublicKey(address));
    assert(info?.executable && info.owner.toBase58() === expected.owner, `Program owner differs: ${address}`);
    let bytes = info.data;
    if (expected.programData) {
      assert(info.owner.equals(LOADER));
      assert.equal(new PublicKey(bytes.subarray(4, 36)).toBase58(), expected.programData);
      bytes = (await connection.getAccountInfo(new PublicKey(expected.programData)))!.data.subarray(45);
    }
    assert.equal(sha256(bytes), expected.sha256, `Mainnet program bytes not preserved: ${address}`);
  }
}
async function main() {
  const samples = Number(process.env.SVM_FORK_SAMPLES || 3),
    marginBps = Number(process.env.SVM_FORK_MARGIN_BPS || 1000);
  const flows = process.env.SVM_FORK_FLOWS ? (process.env.SVM_FORK_FLOWS.split(",") as Flow[]) : [...CASES];
  assert(
    flows.length > 0 && new Set(flows).size === flows.length && flows.every((f) => CASES.includes(f)),
    "Unknown or repeated flow"
  );
  assert(Number.isInteger(samples) && samples >= 1 && samples <= 10);
  assert(Number.isInteger(marginBps) && marginBps >= 0 && marginBps <= 10000);
  const output = path.resolve(
    process.env.SVM_FORK_OUTPUT || path.join(root, `target/fork-cu-${new Date().toISOString().replace(/[:.]/g, "-")}`)
  );
  assert(!existsSync(output), "Output must be a new directory; previous evidence is never overwritten");
  mkdirSync(output, { recursive: true });
  const version = run("solana-test-validator", ["--version"]);
  assert(version.startsWith("solana-test-validator 4.1.2 "), "Use Agave 4.1.2");
  const artifact = resolveSpokeArtifact(root, output);
  const snapshotFile = path.join(output, "mainnet-snapshot.json");
  let snapshot: Snapshot;
  if (process.env.SVM_FORK_SNAPSHOT) {
    snapshot = readSnapshot(process.env.SVM_FORK_SNAPSHOT);
    writeFileSync(snapshotFile, JSON.stringify(snapshot, null, 2) + "\n");
  } else {
    assert(process.env.SVM_FEE_RPC_URL, "Set SVM_FEE_RPC_URL or SVM_FORK_SNAPSHOT");
    console.log("Capturing finalized mainnet accounts (read-only)");
    snapshot = await captureSnapshot(process.env.SVM_FEE_RPC_URL, snapshotFile);
  }
  const spokeIdl = artifact.idl;
  assert(
    snapshot.gatewayIdl && snapshot.gatewayIdl.address === GATEWAY.toBase58(),
    "Snapshot lacks the deployed Gateway IDL"
  );
  const gatewayIdl = path.join(output, "gateway.json");
  writeFileSync(gatewayIdl, JSON.stringify(snapshot.gatewayIdl, null, 2) + "\n");
  const knownFeatures = await withLocalValidator(
    {
      ledger: path.join(output, "feature-probe-ledger"),
      logPath: path.join(output, "feature-probe.log"),
      mint: payer(0).publicKey.toBase58(),
      args: [],
    },
    (url) => features(new Connection(url, "confirmed"))
  );
  const deactivate = knownFeatures.filter((f) => !snapshot.activeFeatures.includes(f));
  const mainnetFeaturesAbsentFromLocalGenesis = snapshot.activeFeatures.filter((f) => !knownFeatures.includes(f));
  const expectedFeatures = knownFeatures.filter((f) => snapshot.activeFeatures.includes(f));
  const program = artifact.binary;
  const rows: Awaited<ReturnType<typeof measure>> = [];
  const provenance = {
    schema: 1,
    head: run("git", ["rev-parse", "HEAD"]),
    trackedProgramDiffSha256: sha256(run("git", ["diff", "HEAD", "--", "programs", "Cargo.toml", "Cargo.lock"])),
    spokeArtifact: artifact.evidence,
    gatewayIdlSource: "mainnet on-chain IDL, archived with snapshot",
    spokeBinarySha256: sha256(readFileSync(program)),
    spokeIdlSha256: sha256(readFileSync(spokeIdl)),
    gatewayIdlSha256: sha256(readFileSync(gatewayIdl)),
    mainnetSnapshotSha256: sha256(readFileSync(snapshotFile)),
    snapshotSlot: snapshot.slot,
    capturedAt: snapshot.capturedAt,
    validator: version,
    verifiedBuildRecipe: JSON.parse(readFileSync(path.join(root, "verified-build.json"), "utf8")),
    spokeFeatures: [],
    node: process.version,
    samples,
    flows,
    marginBps,
    knownActiveFeatures: expectedFeatures,
    mainnetFeaturesAbsentFromLocalGenesis,
    programs: snapshot.programs,
    sourceHashes: Object.fromEntries(
      [
        "scripts/svm/estimateForkCu.ts",
        "scripts/svm/forkSnapshot.ts",
        "scripts/svm/forkArtifacts.ts",
        "scripts/svm/localValidator.ts",
        "test/svm-gateway/fork/config.ts",
        "test/svm-gateway/fork/recorder.ts",
        "test/svm-gateway/fork/measure.ts",
        "test/svm-gateway/wire.ts",
        "test/svm-gateway/fixtures/raydium_cp_swap.244e1241.json",
      ].map((f) => [f, sha256(readFileSync(path.join(root, f)))])
    ),
  };
  writeFileSync(path.join(output, "provenance.json"), JSON.stringify(provenance, null, 2) + "\n");
  for (let sample = 0; sample < samples; sample++) {
    const accountArgs = genesis(snapshot, path.join(output, `accounts-${sample}`), sample);
    const result = await withLocalValidator(
      {
        ledger: path.join(output, `ledger-${sample}`),
        logPath: path.join(output, `validator-${sample}.log`),
        mint: payer(sample).publicKey.toBase58(),
        args: [
          ...accountArgs,
          "--upgradeable-program",
          SPOKE.toBase58(),
          program,
          "none",
          ...deactivate.flatMap((f) => ["--deactivate-feature", f]),
        ],
      },
      async (url) => {
        const connection = new Connection(url, "confirmed");
        await verifyPrograms(connection, snapshot);
        const loadedSpoke = await connection.getAccountInfo(SPOKE);
        assert(loadedSpoke && loadedSpoke.owner.equals(LOADER));
        const spokeData = await connection.getAccountInfo(new PublicKey(loadedSpoke.data.subarray(4, 36)));
        assert(
          spokeData && sha256(spokeData.data.subarray(45)) === artifact.evidence.binarySha256,
          "Loaded Spoke differs from CI binary"
        );
        assert.deepEqual(await features(connection), expectedFeatures, "Validator feature alignment failed");
        return measure(url, output, sample, spokeIdl, gatewayIdl, marginBps, flows);
      }
    );
    rows.push(...result);
  }
  assert.equal(rows.length, samples * flows.length);
  const feeManifest = process.env.SVM_FORK_FEE_MANIFEST
    ? JSON.parse(readFileSync(process.env.SVM_FORK_FEE_MANIFEST, "utf8"))
    : undefined;
  const feeInputs = rows.map((r) => ({
    flow: r.flow,
    sample: r.sample,
    transactions: r.transactions.map((tx) => {
      const matchedComponents = (feeManifest?.markets || []).filter(
        (m: { writable_accounts: string[] }) =>
          m.writable_accounts.length && m.writable_accounts.every((a) => tx.writableAccounts.includes(a))
      );
      const covered = new Set<string>(
        matchedComponents.flatMap((m: { writable_accounts: string[] }) => m.writable_accounts)
      );
      return {
        ...tx,
        matchedComponents: matchedComponents.map((m: { name: string }) => m.name),
        uncoveredWritableAccounts: tx.writableAccounts.filter((a) => !covered.has(a)),
      };
    }),
  }));
  writeFileSync(
    path.join(output, "fee-inputs.json"),
    JSON.stringify({ feeManifest: feeManifest ?? null, rows: feeInputs }, null, 2) + "\n"
  );
  const summaries = flows.map((flow) => {
    const selected = rows.filter((r) => r.flow === flow);
    return {
      flow,
      executionMin: Math.min(...selected.map((r) => r.execution)),
      executionMax: Math.max(...selected.map((r) => r.execution)),
      totalMin: Math.min(...selected.map((r) => r.totalConsumedCu)),
      totalMax: Math.max(...selected.map((r) => r.totalConsumedCu)),
    };
  });
  writeFileSync(
    path.join(output, "results.json"),
    JSON.stringify({ provenance, completed: true, summaries, rows }, null, 2) + "\n"
  );
  console.table(summaries);
  console.log(`Results: ${output}`);
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
