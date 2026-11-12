import { strict as assert } from "assert";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { execFileSync } from "child_process";
import { tmpdir } from "os";
import path from "path";
import { AccountLayout, NATIVE_MINT, getAssociatedTokenAddressSync } from "@solana/spl-token";
import { paddedLimit, assertLoopback } from "./recorder";
import { genesis, sha256, Snapshot } from "../../../scripts/svm/forkSnapshot";
import { extractReleaseFile, verifySpokeSources } from "../../../scripts/svm/forkArtifacts";
import { STATE, SPOKE, MAINNET_GENESIS, VAULT_AUTHORITY, LOADER, GATEWAY } from "./config";
describe("Fork CU estimator boundaries", () => {
  it("verifies both the release archive and the selected member before using it", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "fork-release-test-"));
    try {
      const bytes = Buffer.from([0, 255, 128, 42]);
      writeFileSync(path.join(dir, "svm_spoke.so"), bytes);
      const archive = path.join(dir, "production.tar.gz");
      execFileSync("tar", ["-czf", archive, "-C", dir, "svm_spoke.so"]);
      const pin = { sha256: sha256(readFileSync(archive)), member: "svm_spoke.so" };
      assert.deepEqual(extractReleaseFile(archive, pin, sha256(bytes)), bytes);
      assert.throws(() => extractReleaseFile(archive, { ...pin, sha256: "wrong" }, sha256(bytes)), /archive hash/);
      assert.throws(() => extractReleaseFile(archive, pin, sha256("test-feature binary")), /member hash/);
      assert.throws(() => extractReleaseFile(archive, { ...pin, member: "missing.so" }, sha256(bytes)), /tar failed/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it("requires a matching release when program sources or build inputs change", () => {
    const root = mkdtempSync(path.join(tmpdir(), "fork-artifact-test-"));
    try {
      const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
      git("init", "--quiet");
      mkdirSync(path.join(root, "programs"));
      writeFileSync(path.join(root, "programs", "source.rs"), "original");
      git("add", "programs");
      git(
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.com",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "--quiet",
        "-m",
        "fixture"
      );
      const commit = git("rev-parse", "HEAD");
      assert.doesNotThrow(() => verifySpokeSources(root, commit));
      writeFileSync(path.join(root, "programs", "source.rs"), "modified");
      assert.throws(() => verifySpokeSources(root, commit), /publish a matching release/);
      writeFileSync(path.join(root, "programs", "source.rs"), "original");
      writeFileSync(path.join(root, "Cargo.lock"), "changed dependency");
      git("add", "Cargo.lock");
      assert.throws(() => verifySpokeSources(root, commit), /publish a matching release/);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
  it("rejects invalid CU estimates and does not silently cap an insufficient budget", () => {
    assert.equal(paddedLimit(100001, 1000), 110002);
    for (const units of [0, -1, NaN, Infinity, 1.5, 1400000]) assert.throws(() => paddedLimit(units, 1000));
    assert.throws(() => paddedLimit(100000, -1));
    assert.throws(() => paddedLimit(100000, 10001));
  });
  it("only accepts loopback submission endpoints", () => {
    for (const url of ["http://127.0.0.1:8899", "http://localhost:8899", "http://[::1]:8899"])
      assert.doesNotThrow(() => assertLoopback(url));
    for (const url of ["https://api.mainnet-beta.solana.com", "http://127.0.0.1.example.com", "https://localhost:8899"])
      assert.throws(() => assertLoopback(url));
  });
  it("retains the original snapshot and patches only pause flags in Spoke state", () => {
    const data = Buffer.alloc(114, 7);
    data[8] = 1;
    data[9] = 1;
    data.fill(0, 42, 50);
    const snapshot: Snapshot = {
      capturedAt: "test",
      slot: 1,
      genesisHash: MAINNET_GENESIS,
      activeFeatures: [],
      programs: {},
      accounts: {
        [STATE.toBase58()]: {
          lamports: 100000000,
          owner: SPOKE.toBase58(),
          executable: false,
          rentEpoch: 0,
          data: [data.toString("base64"), "base64"],
        },
      },
    };
    const programData = Buffer.alloc(64, 3);
    programData.writeUInt32LE(3, 0);
    programData.writeBigUInt64LE(456000000n, 4);
    snapshot.accounts[VAULT_AUTHORITY.toBase58()] = {
      lamports: 10000000,
      owner: LOADER.toBase58(),
      executable: false,
      rentEpoch: 0,
      data: [programData.toString("base64"), "base64"],
    };
    snapshot.programs[GATEWAY.toBase58()] = {
      owner: LOADER.toBase58(),
      programData: VAULT_AUTHORITY.toBase58(),
      sha256: "test",
    };
    const before = JSON.stringify(snapshot);
    const dir = mkdtempSync(path.join(tmpdir(), "fork-cu-test-"));
    try {
      genesis(snapshot, path.join(dir, "accounts"), 0);
      assert.equal(JSON.stringify(snapshot), before);
      const state = JSON.parse(readFileSync(path.join(dir, "accounts", STATE.toBase58() + ".json"), "utf8"));
      const patched = Buffer.from(state.account.data[0], "base64");
      assert.equal(patched[8], 0);
      assert.equal(patched[9], 0);
      patched[8] = 1;
      patched[9] = 1;
      assert.deepEqual(patched, data);
      const pd = JSON.parse(readFileSync(path.join(dir, "accounts", VAULT_AUTHORITY.toBase58() + ".json"), "utf8"));
      const patchedProgram = Buffer.from(pd.account.data[0], "base64");
      assert.equal(patchedProgram.readBigUInt64LE(4), 0n);
      assert.deepEqual(patchedProgram.subarray(12), programData.subarray(12));
      const vault = getAssociatedTokenAddressSync(NATIVE_MINT, VAULT_AUTHORITY, true);
      const account = JSON.parse(readFileSync(path.join(dir, "accounts", vault.toBase58() + ".json"), "utf8")).account;
      const token = AccountLayout.decode(Buffer.from(account.data[0], "base64"));
      assert.equal(token.amount, 0n);
      assert.equal(token.isNativeOption, 1);
      assert.equal(BigInt(account.lamports), token.isNative);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
