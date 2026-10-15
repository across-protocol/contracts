import { spawn, spawnSync } from "child_process";
import { openSync, closeSync } from "fs";
import { createServer } from "net";
import path from "path";
import { GATEWAY_COMMIT } from "../../test/svm-gateway/wire";

export function preparePinnedCheckout(options: {
  name: string;
  repository: string;
  commit: string;
  destination: string;
  existing?: string;
}): string {
  const checkout = path.resolve(options.existing || options.destination);
  const git = (args: string[], cwd?: string) => {
    const result = spawnSync("git", args, { cwd, encoding: "utf8" });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr}`);
    return result.stdout.trim();
  };
  if (!options.existing) {
    git(["clone", options.repository, checkout]);
    git(["checkout", "--detach", options.commit], checkout);
  }
  if (
    git(["rev-parse", "HEAD"], checkout) !== options.commit ||
    git(["status", "--porcelain", "--untracked-files=normal"], checkout)
  )
    throw new Error(`${options.name} checkout must be clean at ${options.commit}`);
  return checkout;
}

export function prepareGatewayCheckout(work: string): string {
  return preparePinnedCheckout({
    name: "Gateway",
    repository: "git@github.com:across-protocol/solana-v5.git",
    commit: GATEWAY_COMMIT,
    destination: path.join(work, "solana-v5"),
    existing: process.env.SVM_GATEWAY_CHECKOUT,
  });
}

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = (server.address() as { port: number }).port;
  await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  return port;
}

export async function withLocalValidator<T>(
  options: { ledger: string; logPath: string; mint: string; args: string[] },
  run: (url: string) => T | Promise<T>
): Promise<T> {
  const port = await freePort();
  const args = [
    "--ledger",
    options.ledger,
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
    options.mint,
    ...options.args,
  ];
  const url = `http://127.0.0.1:${port}`;
  const log = openSync(options.logPath, "w");
  const validator = spawn("solana-test-validator", args, { stdio: ["ignore", log, log] });
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
    let ready = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      if (spawnError) throw spawnError;
      if (validator.exitCode !== null || validator.signalCode !== null)
        throw new Error(`Validator exited; see ${options.logPath}`);
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "getSlot", params: [{ commitment: "confirmed" }] }),
          signal: AbortSignal.timeout(2_000),
        });
        const { result } = (await response.json()) as { result?: number };
        if (response.ok && typeof result === "number" && result > 10) {
          ready = true;
          break;
        }
      } catch {
        /* RPC starts after genesis setup. */
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (!ready) throw new Error(`Validator startup timed out; see ${options.logPath}`);
    return await run(url);
  } finally {
    stop();
    await closed;
    closeSync(log);
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
}
