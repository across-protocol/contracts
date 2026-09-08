// Separate validator: the ordinary Anchor suite installs mock_gateway at the
// same address. Build both foreign programs from an immutable source checkout.
import { spawn, spawnSync } from "child_process";
import { mkdirSync, mkdtempSync, readFileSync, openSync, closeSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { createServer } from "net";
import { Keypair } from "@solana/web3.js";
import { GATEWAY, PREFUNDED, GATEWAY_COMMIT } from "../../test/svm-gateway/reference";

function run(command: string, args: string[], cwd = process.cwd()) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit", env: process.env });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
}
async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}
async function main() {
  const work = mkdtempSync(path.join(tmpdir(), "acp184-gateway-"));
  const checkout = process.env.SVM_GATEWAY_CHECKOUT || path.join(work, "solana-v5");
  if (!process.env.SVM_GATEWAY_CHECKOUT) {
    run("git", ["clone", "https://github.com/across-protocol/solana-v5.git", checkout]);
    run("git", ["checkout", "--detach", GATEWAY_COMMIT], checkout);
  }
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: checkout, encoding: "utf8" });
  const dirty = spawnSync("git", ["status", "--porcelain", "--untracked-files=normal"], {
    cwd: checkout,
    encoding: "utf8",
  });
  if (head.status !== 0 || head.stdout.trim() !== GATEWAY_COMMIT || dirty.status !== 0 || dirty.stdout.trim()) {
    throw new Error(`Gateway checkout must be clean at ${GATEWAY_COMMIT}`);
  }
  const foreignAnchor = process.env.SVM_GATEWAY_ANCHOR || "anchor";
  for (const name of ["gateway", "prefunded_adapter"]) {
    run(foreignAnchor, ["build", "--program-name", name, "--ignore-keys", "--no-idl"], checkout);
  }
  // IS_TEST is not sufficient for local Anchor builds: pass the feature explicitly.
  const spokeAnchor = process.env.SVM_SPOKE_ANCHOR || "anchor";
  run("cargo", [
    "build-sbf",
    "--tools-version",
    "v1.52",
    "--manifest-path",
    "programs/svm-spoke/Cargo.toml",
    "--sbf-out-dir",
    "target/deploy",
    "--features",
    "test",
  ]);
  for (const directory of ["target/idl", "target/types"]) mkdirSync(directory, { recursive: true });
  run(spokeAnchor, [
    "idl",
    "build",
    "--program-name",
    "svm_spoke",
    "--out",
    "target/idl/svm_spoke.json",
    "--out-ts",
    "target/types/svm_spoke.ts",
    "--",
    "--features",
    "test",
  ]);

  const walletPath = path.resolve("test/svm/keys/localnet-wallet.json");
  const wallet = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(walletPath, "utf8"))));
  const rpcPort = await freePort();
  const faucetPort = await freePort();
  const url = `http://127.0.0.1:${rpcPort}`;
  const logPath = path.join(work, "validator.log");
  const log = openSync(logPath, "w");
  const validator = spawn(
    "solana-test-validator",
    [
      "--ledger",
      path.join(work, "ledger"),
      "--bind-address",
      "127.0.0.1",
      "--rpc-port",
      String(rpcPort),
      "--faucet-port",
      String(faucetPort),
      "--gossip-port",
      String(await freePort()),
      "--quiet",
      "--mint",
      wallet.publicKey.toBase58(),
      "--upgradeable-program",
      GATEWAY.toBase58(),
      path.join(checkout, "target/deploy/gateway.so"),
      wallet.publicKey.toBase58(),
      "--upgradeable-program",
      PREFUNDED.toBase58(),
      path.join(checkout, "target/deploy/prefunded_adapter.so"),
      wallet.publicKey.toBase58(),
      "--upgradeable-program",
      "DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru",
      path.resolve("target/deploy/svm_spoke.so"),
      wallet.publicKey.toBase58(),
    ],
    { stdio: ["ignore", log, log] }
  );
  let spawnFailure: Error | undefined;
  validator.once("error", (error) => {
    spawnFailure = error;
  });
  const closed = new Promise<void>((resolve) => validator.once("close", () => resolve()));
  const stop = () => validator.kill("SIGTERM");
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    let ready = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (spawnFailure) throw spawnFailure;
      if (validator.exitCode !== null || validator.signalCode !== null)
        throw new Error(`Validator exited; see ${logPath}`);
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "getHealth" }),
        });
        if (((await response.json()) as { result?: string }).result === "ok") {
          ready = true;
          break;
        }
      } catch {
        /* RPC starts after genesis setup. */
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (!ready) throw new Error(`Validator did not start; see ${logPath}`);
    console.log(`Real Gateway ${GATEWAY_COMMIT}; validator logs: ${logPath}`);
    const tests = spawnSync(
      "yarn",
      ["ts-mocha", "--bail", "-p", "tsconfig.json", "-t", "1000000", "test/svm-gateway/*.ts"],
      {
        stdio: "inherit",
        env: {
          ...process.env,
          ANCHOR_PROVIDER_URL: url,
          ANCHOR_WALLET: walletPath,
          NODE_OPTIONS: "--no-experimental-strip-types",
        },
      }
    );
    if (tests.error || tests.status !== 0) throw new Error(`Real-Gateway tests failed; see ${logPath}`);
  } finally {
    stop();
    await closed;
    closeSync(log);
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
