import { strict as assert } from "assert";
import { execFileSync } from "child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import path from "path";
import { preparePinnedCheckout, withLocalValidator } from "../../scripts/svm/localValidator";

describe("Local validator runner helpers", function () {
  this.timeout(15_000);
  let work: string;
  let previousPath: string | undefined;
  let listeners: number[];

  beforeEach(() => {
    work = mkdtempSync(path.join(tmpdir(), "svm-runner-test-"));
    previousPath = process.env.PATH;
    listeners = [process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")];
  });
  afterEach(() => {
    process.env.PATH = previousPath;
    assert.deepEqual([process.listenerCount("SIGINT"), process.listenerCount("SIGTERM")], listeners);
    rmSync(work, { recursive: true, force: true });
  });

  it("clones an exact revision and rejects wrong revisions, tracked edits and untracked files", () => {
    const source = path.join(work, "source");
    mkdirSync(source);
    const git = (...args: string[]) => execFileSync("git", args, { cwd: source, encoding: "utf8" }).trim();
    git("init", "--quiet");
    writeFileSync(path.join(source, "tracked"), "original");
    git("add", "tracked");
    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "--quiet", "-m", "fixture");
    const commit = git("rev-parse", "HEAD");
    const options = { name: "Fixture", repository: source, commit, destination: path.join(work, "clone") };
    const clone = preparePinnedCheckout(options);
    assert.equal(readFileSync(path.join(clone, "tracked"), "utf8"), "original");
    assert.equal(preparePinnedCheckout({ ...options, existing: clone }), clone);
    assert.throws(
      () => preparePinnedCheckout({ ...options, existing: clone, commit: "0".repeat(40) }),
      /must be clean/
    );
    writeFileSync(path.join(clone, "tracked"), "modified");
    assert.throws(() => preparePinnedCheckout({ ...options, existing: clone }), /must be clean/);
    writeFileSync(path.join(clone, "tracked"), "original");
    writeFileSync(path.join(clone, "untracked"), "unexpected");
    execFileSync("git", ["config", "status.showUntrackedFiles", "no"], { cwd: clone });
    assert.throws(() => preparePinnedCheckout({ ...options, existing: clone }), /must be clean/);
  });

  function validatorOptions(args: string[] = []) {
    const bin = path.join(work, "bin");
    mkdirSync(bin);
    writeFileSync(
      path.join(bin, "solana-test-validator"),
      `#!${process.execPath}
const fs = require("fs"), http = require("http");
const args = process.argv.slice(2);
const ledger = args[args.indexOf("--ledger") + 1];
fs.writeFileSync(ledger, String(process.pid));
if (args.includes("--fixture-exit")) process.exit(7);
let requests = 0;
http.createServer((req, res) => {
  let body = "";
  req.on("data", chunk => body += chunk);
  req.on("end", () => {
    const rpc = JSON.parse(body);
    if (rpc.method !== "getSlot" || rpc.params[0].commitment !== "confirmed") process.exit(8);
    res.setHeader("Content-Type", "application/json");
    fs.writeFileSync(ledger + ".requests", String(++requests));
    res.end(JSON.stringify({result: requests > 1 ? 11 : 0}));
  });
}).listen(Number(args[args.indexOf("--rpc-port") + 1]), "127.0.0.1");
`,
      { mode: 0o755 }
    );
    process.env.PATH = `${bin}:${previousPath}`;
    return { ledger: path.join(work, "pid"), logPath: path.join(work, "validator.log"), mint: "fixture", args };
  }

  for (const fail of [false, true]) {
    it(`stops the validator and removes signal listeners after callback ${fail ? "failure" : "success"}`, async () => {
      const options = validatorOptions();
      const result = withLocalValidator(options, (url) => {
        assert.match(url, /^http:\/\/127\.0\.0\.1:\d+$/);
        assert.equal(readFileSync(options.ledger + ".requests", "utf8"), "2", "wait for the confirmed slot");
        if (fail) throw new Error("callback failed");
        return "completed";
      });
      if (fail) await assert.rejects(result, /callback failed/);
      else assert.equal(await result, "completed");
      const pid = Number(readFileSync(options.ledger, "utf8"));
      assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
    });
  }

  it("rejects a validator that exits before readiness without running the callback", async () => {
    await assert.rejects(
      withLocalValidator(validatorOptions(["--fixture-exit"]), () => assert.fail("callback ran")),
      /Validator exited/
    );
  });

  it("rejects spawn failure and removes signal listeners", async () => {
    const options = validatorOptions();
    process.env.PATH = path.join(work, "missing");
    await assert.rejects(
      withLocalValidator(options, () => assert.fail("callback ran")),
      { code: "ENOENT" }
    );
  });
});
