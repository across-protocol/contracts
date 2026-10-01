// SVM compute must be measured by Agave; Foundry cannot execute these programs.
import { strict as assert } from "assert";
import { isDeepStrictEqual } from "util";
import { spawn, spawnSync } from "child_process";
import { createHash } from "crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, openSync, closeSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { createServer } from "net";
import { Connection } from "@solana/web3.js";
import { GATEWAY, GATEWAY_COMMIT } from "../../test/svm-gateway/wire";
import {
  CASES,
  LEGACY_COMMIT,
  Measurement,
  SAMPLES,
  SPOKE,
  VALIDATOR_VERSION,
  WALLET,
} from "../../test/svm-gateway/cu/config";

const root = path.resolve(__dirname, "../..");
const output = path.resolve(process.env.SVM_CU_OUTPUT || path.join(root, "target/cu-benchmark"));
const cache = path.resolve(process.env.SVM_CU_BUILD_ROOT || path.join(root, "target/cu-builds"));
const work = mkdtempSync(path.join(tmpdir(), "across-cu-"));
const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");

function run(command: string, args: string[], cwd = root, env: NodeJS.ProcessEnv = process.env, input?: Buffer) {
  const result = spawnSync(command, args, { cwd, env, input, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
  return result.stdout.trim();
}

function build(cwd: string, name: string, tools: string, anchor: string, test = false) {
  const directory = path.join(cache, name);
  const env = { ...process.env, CARGO_TARGET_DIR: directory };
  const binaryName = name === "gateway" ? "gateway" : "svm_spoke";
  const manifest = name === "gateway" ? "programs/gateway/Cargo.toml" : "programs/svm-spoke/Cargo.toml";
  console.log(`Building ${name} with platform-tools ${tools}`);
  const args = ["--tools-version", tools, "--manifest-path", manifest, "--sbf-out-dir", path.join(work, name)];
  if (test) args.push("--features", "test");
  args.push("--", "--locked");
  const command = process.env.SVM_CU_SBF || "cargo-build-sbf";
  const logPath = path.join(output, `${name}-build.log`);
  const log = openSync(logPath, "w");
  try {
    const result = spawnSync("bash", [path.join(root, "scripts/svm/buildHelpers/runSbfBuild.sh"), command, ...args], {
      cwd,
      env,
      stdio: ["ignore", log, log],
    });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${name} SBF build failed; see ${logPath}`);
  } finally {
    closeSync(log);
  }
  const idlPath = path.join(work, `${name}.json`);
  console.log(`Generating ${name} IDL`);
  run(
    anchor,
    [
      "idl",
      "build",
      "--program-name",
      binaryName,
      "--out",
      idlPath,
      "--",
      "--locked",
      ...(test ? ["--features", "test"] : []),
    ],
    cwd,
    env
  );
  if (name === "v5") {
    // Include schemas carried inside adapter Vec<u8>, as in includeV5IdlTypes.ts, without generating package clients.
    const types = JSON.parse(
      run(
        "cargo",
        ["run", "--quiet", "--locked", "-p", "svm-spoke", "--bin", "export_v5_types", "--features", "idl-build"],
        cwd,
        env
      ),
      (key, value) => (key === "name" && typeof value === "string" ? value.split("::").pop() : value)
    );
    const idl = JSON.parse(readFileSync(idlPath, "utf8"));
    for (const type of types) {
      const existing = idl.types.find((entry: { name: string }) => entry.name === type.name);
      if (existing && !isDeepStrictEqual(existing, type)) throw new Error(`Conflicting type ${type.name}`);
      if (!existing) idl.types.push(type);
    }
    writeFileSync(idlPath, JSON.stringify(idl));
  }
  return { binary: path.join(work, name, `${binaryName}.so`), idl: idlPath, tools };
}

async function freePort() {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  return port;
}

async function benchmark(mode: "legacy" | "v5", spoke: ReturnType<typeof build>, gateway: ReturnType<typeof build>) {
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  const log = openSync(path.join(output, `${mode}-validator.log`), "w");
  const validator = spawn(
    "solana-test-validator",
    [
      "--ledger",
      path.join(work, `${mode}-ledger`),
      "--bind-address",
      "127.0.0.1",
      "--rpc-port",
      String(port),
      "--faucet-port",
      String(await freePort()),
      "--gossip-port",
      String(await freePort()),
      "--quiet",
      "--mint",
      WALLET.publicKey.toBase58(),
      "--upgradeable-program",
      SPOKE.toBase58(),
      spoke.binary,
      WALLET.publicKey.toBase58(),
      ...(mode === "v5"
        ? ["--upgradeable-program", GATEWAY.toBase58(), gateway.binary, WALLET.publicKey.toBase58()]
        : []),
    ],
    { stdio: ["ignore", log, log] }
  );
  let spawnError: Error | undefined;
  validator.once("error", (error) => {
    spawnError = error;
  });
  const closed = new Promise<void>((resolve) => validator.once("close", () => resolve()));
  const stop = () => {
    validator.kill("SIGTERM");
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    const connection = new Connection(url, "confirmed");
    let ready = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (spawnError) throw spawnError;
      if (validator.exitCode !== null) throw new Error(`Validator exited: ${mode}`);
      try {
        if ((await connection.getSlot()) > 10) {
          ready = true;
          break;
        }
      } catch {
        /* genesis startup */
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (!ready) throw new Error(`Validator startup timed out: ${mode}`);
    const env = {
      ...process.env,
      NODE_OPTIONS: "--no-experimental-strip-types",
      SVM_CU_MODE: mode,
      SVM_CU_RPC: url,
      SVM_CU_OUTPUT: output,
      SVM_CU_SPOKE_IDL: spoke.idl,
      SVM_CU_GATEWAY_IDL: gateway.idl,
    };
    console.log(`Measuring ${mode} (five fixed fixtures)`);
    console.log(run("yarn", ["ts-node", "test/svm-gateway/cu/measure.ts"], root, env));
  } finally {
    stop();
    await closed;
    closeSync(log);
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
}

async function main() {
  mkdirSync(output, { recursive: true });
  const validatorVersion = run("solana-test-validator", ["--version"]);
  if (!validatorVersion.startsWith(`solana-test-validator ${VALIDATOR_VERSION} `))
    throw new Error(`Use Agave ${VALIDATOR_VERSION}; got ${validatorVersion}`);
  const spokeAnchor = process.env.SVM_SPOKE_ANCHOR || "anchor";
  const gatewayAnchor = process.env.SVM_GATEWAY_ANCHOR || "anchor";
  const anchorVersions = [run(spokeAnchor, ["--version"]), run(gatewayAnchor, ["--version"])];
  if (anchorVersions[0] !== "anchor-cli 0.31.1" || anchorVersions[1] !== "anchor-cli 1.1.2")
    throw new Error(`Set SVM_SPOKE_ANCHOR (0.31.1) and SVM_GATEWAY_ANCHOR (1.1.2): ${anchorVersions}`);
  const legacy = path.join(work, "legacy-source");
  mkdirSync(legacy);
  const archive = spawnSync(
    "git",
    ["archive", LEGACY_COMMIT, "Cargo.toml", "Cargo.lock", "Anchor.toml", "programs", "idls"],
    { cwd: root, maxBuffer: 32 * 1024 * 1024 }
  );
  if (archive.status !== 0)
    throw new Error(`Missing legacy commit ${LEGACY_COMMIT}; fetch repository history first. ${archive.stderr}`);
  run("tar", ["-x", "-C", legacy], root, process.env, archive.stdout);
  const checkout = process.env.SVM_GATEWAY_CHECKOUT || path.join(work, "solana-v5");
  if (!process.env.SVM_GATEWAY_CHECKOUT) {
    run("git", ["clone", "git@github.com:across-protocol/solana-v5.git", checkout]);
    run("git", ["checkout", "--detach", GATEWAY_COMMIT], checkout);
  }
  if (run("git", ["rev-parse", "HEAD"], checkout) !== GATEWAY_COMMIT || run("git", ["status", "--porcelain"], checkout))
    throw new Error(`Gateway checkout must be clean at ${GATEWAY_COMMIT}`);
  // Sequential builds: cargo-build-sbf updates a global Rust toolchain link.
  const builds = {
    legacy: build(legacy, "legacy", "v1.44", spokeAnchor, true),
    v5: build(root, "v5", "v1.52", spokeAnchor, true),
    gateway: build(checkout, "gateway", "v1.54", gatewayAnchor),
  };
  await benchmark("legacy", builds.legacy, builds.gateway);
  await benchmark("v5", builds.v5, builds.gateway);
  const measurements: Measurement[] = ["legacy", "v5"].flatMap(
    (mode) => JSON.parse(readFileSync(path.join(output, `${mode}.json`), "utf8")).measurements
  );
  assert.equal(measurements.length, CASES.length * SAMPLES.length, "Complete benchmark matrix");
  for (const name of CASES) {
    const rows = measurements.filter((row) => row.case === name);
    assert.deepEqual(
      rows.map((row) => row.sample),
      SAMPLES,
      `Missing or repeated fixtures: ${name}`
    );
    for (const row of rows) {
      assert(row.execution > 0 && [row.execution, row.approval, row.buffer].every(Number.isSafeInteger));
      assert(row.approval >= 0 && row.buffer >= 0);
      assert.equal(row.total, row.execution + row.approval + row.buffer);
    }
  }
  const baselinePath = path.join(root, "test/svm-gateway/cu/baseline.json");
  const baseline:
    | { measurements: Measurement[]; fixtureSha256: string; programs: unknown; runtime: unknown }
    | undefined = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, "utf8")) : undefined;
  const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
  console.table(
    CASES.map((name) => {
      const rows = measurements.filter((row) => row.case === name);
      const previous = baseline?.measurements.filter((row) => row.case === name);
      return {
        case: name,
        execution: median(rows.map((r) => r.execution)),
        approval: median(rows.map((r) => r.approval)),
        buffer: median(rows.map((r) => r.buffer)),
        total: median(rows.map((r) => r.total)),
        delta: previous?.length ? median(rows.map((r) => r.total)) - median(previous.map((r) => r.total)) : "n/a",
      };
    })
  );
  const manifest = {
    schema: 1,
    fixture: "across-cu-v1",
    head: run("git", ["rev-parse", "HEAD"]),
    legacy: LEGACY_COMMIT,
    gateway: GATEWAY_COMMIT,
    trackedDiffSha256: sha256(run("git", ["diff", "HEAD", "--", "programs", "Cargo.toml", "Cargo.lock"])),
    validatorVersion,
    anchorVersions,
    node: process.version,
    spokeFeatures: ["test"],
    sbfVersion: run(process.env.SVM_CU_SBF || "cargo-build-sbf", ["--version"]),
    fixtureSha256: sha256(
      [
        "scripts/svm/benchmarkCu.ts",
        "test/svm-gateway/cu/config.ts",
        "test/svm-gateway/cu/measure.ts",
        "test/svm-gateway/wire.ts",
      ]
        .map((file) => `${file}\n${readFileSync(path.join(root, file), "utf8")}`)
        .join("\n")
    ),
    programs: Object.fromEntries(
      Object.entries(builds).map(([name, entry]) => [
        name,
        {
          tools: entry.tools,
          binarySha256: sha256(readFileSync(entry.binary)),
          idlSha256: sha256(readFileSync(entry.idl)),
        },
      ])
    ),
    runtime: Object.fromEntries(
      ["legacy", "v5"].map((mode) => [
        mode,
        JSON.parse(readFileSync(path.join(output, `${mode}.json`), "utf8")).runtime,
      ])
    ),
    measurements,
  };
  if (JSON.stringify(manifest.runtime.legacy) !== JSON.stringify(manifest.runtime.v5))
    throw new Error("Legacy and V5 validator/token-program environments differ");
  if (
    baseline &&
    (!isDeepStrictEqual(baseline.programs, manifest.programs) ||
      !isDeepStrictEqual(baseline.runtime, manifest.runtime) ||
      baseline.fixtureSha256 !== manifest.fixtureSha256)
  )
    console.warn(
      "Baseline provenance differs. Inspect fixture, program and runtime hashes before interpreting deltas."
    );
  writeFileSync(path.join(output, "results.json"), JSON.stringify(manifest, null, 2) + "\n");
  if (process.argv.includes("--update-baseline")) writeFileSync(baselinePath, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`Results and receipts: ${output}\nBuilds and ledgers: ${work}`);
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
