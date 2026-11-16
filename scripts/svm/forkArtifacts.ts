import { strict as assert } from "assert";
import { spawnSync } from "child_process";
import { readFileSync, writeFileSync } from "fs";
import path from "path";
import { sha256 } from "./forkSnapshot";
import release from "../../test/svm-gateway/fork/spoke-release.json";

const SOURCE_PATHS = [
  "programs",
  "Cargo.toml",
  "Cargo.lock",
  "Anchor.toml",
  "verified-build.json",
  "scripts/svm/buildHelpers",
];

function run(command: string, args: string[], cwd?: string): Buffer {
  const r = spawnSync(command, args, { cwd, maxBuffer: 64 * 1024 * 1024 });
  if (r.error) throw r.error;
  assert.equal(r.status, 0, `${command} failed: ${r.stderr}`);
  return r.stdout;
}

// Extract only the pinned member to memory; never unpack archive paths into the checkout.
export function extractReleaseFile(archive: string, pin: { sha256: string; member: string }, fileHash: string) {
  assert.equal(sha256(readFileSync(archive)), pin.sha256, "Release archive hash mismatch");
  const bytes = run("tar", ["-xOzf", archive, pin.member]);
  assert.equal(sha256(bytes), fileHash, "Release member hash mismatch");
  return bytes;
}

export function verifySpokeSources(root: string, sourceCommit: string) {
  assert.equal(
    run("git", ["diff", sourceCommit, "--", ...SOURCE_PATHS], root)
      .toString()
      .trim(),
    "",
    "Program sources, dependencies or build recipe differ from the pinned release; publish a matching release and update spoke-release.json before measuring"
  );
}

export function resolveSpokeArtifact(root: string, output: string) {
  if (spawnSync("git", ["cat-file", "-e", `${release.sourceCommit}^{commit}`], { cwd: root }).status !== 0) {
    run("git", ["fetch", "--no-tags", "https://github.com/across-protocol/contracts.git", release.sourceCommit], root);
  }
  verifySpokeSources(root, release.sourceCommit);
  const binary = path.join(output, "svm_spoke.so"),
    idl = path.join(output, "svm_spoke.json");
  for (const [name, pin, destination, hash] of [
    ["production", release.release.production, binary, release.binarySha256],
    ["package", release.release.package, idl, release.idlSha256],
  ] as const) {
    const archive = path.join(output, `${name}.tar.gz`);
    run("curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", archive, pin.url]);
    writeFileSync(destination, extractReleaseFile(archive, pin, hash));
  }
  writeFileSync(path.join(output, "spoke-artifact.json"), JSON.stringify(release, null, 2) + "\n");
  console.log(`Verified production Spoke ${release.binarySha256.slice(0, 12)} from ${release.release.tag}`);
  return { binary, idl, evidence: release };
}
