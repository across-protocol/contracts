import { strict as assert } from "assert";
import { spawnSync } from "child_process";
import { copyFileSync, readFileSync, writeFileSync } from "fs";
import path from "path";
import { sha256 } from "./forkSnapshot";
const SOURCE_PATHS = [
  "programs",
  "Cargo.toml",
  "Cargo.lock",
  "Anchor.toml",
  "verified-build.json",
  "scripts/svm/buildHelpers",
];
function run(command: string, args: string[], cwd: string) {
  const r = spawnSync(command, args, { cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.error) throw r.error;
  assert.equal(r.status, 0, `${command} failed: ${r.stderr}`);
  return r.stdout.trim();
}
export function resolveSpokeArtifact(root: string, output: string) {
  const head = run("git", ["rev-parse", "HEAD"], root);
  let evidence: {
    sourceCommit: string;
    ciRun: number;
    ciJob: number;
    ciUrl: string;
    binarySha256: string;
    idlSha256: string;
  };
  let sourceBinary = path.resolve(process.env.SVM_FORK_SPOKE_BINARY || path.join(root, "target/deploy/svm_spoke.so"));
  let sourceIdl: string;
  if (process.env.SVM_FORK_ARTIFACTS) {
    const directory = path.resolve(process.env.SVM_FORK_ARTIFACTS);
    evidence = JSON.parse(readFileSync(path.join(directory, "spoke-artifact.json"), "utf8"));
    sourceBinary = path.join(directory, "svm_spoke.so");
    sourceIdl = path.join(directory, "svm_spoke.json");
  } else {
    const id =
      process.env.SVM_FORK_CI_RUN ||
      JSON.parse(
        run(
          "gh",
          [
            "run",
            "list",
            "--repo",
            "across-protocol/contracts",
            "--commit",
            head,
            "--workflow",
            "Checks",
            "--status",
            "success",
            "--json",
            "databaseId",
            "--limit",
            "1",
          ],
          root
        )
      )[0]?.databaseId;
    assert(
      id,
      "Set SVM_FORK_CI_RUN to a successful run with identical Spoke sources, or SVM_FORK_ARTIFACTS to a previously verified run directory"
    );
    const meta = JSON.parse(run("gh", ["api", `repos/across-protocol/contracts/actions/runs/${id}`], root));
    assert.equal(meta.conclusion, "success");
    const jobs = JSON.parse(
      run("gh", ["api", `repos/across-protocol/contracts/actions/runs/${id}/jobs?per_page=100`], root)
    ).jobs;
    const job = jobs.find((j: any) => j.name === "Test verified SVM build" && j.conclusion === "success");
    assert(
      job?.steps.some(
        (s: any) => s.name === "Test verified production binary in a fresh ledger" && s.conclusion === "success"
      ),
      "CI must have tested the production binary"
    );
    const log = run("gh", ["api", `repos/across-protocol/contracts/actions/jobs/${job.id}/logs`], root);
    const hashes = [...log.matchAll(/Production Spoke SHA-256: ([0-9a-f]{64})/g)].map((m) => m[1]);
    assert.equal(hashes.length, 1, "Expected one production binary hash in CI log");
    writeFileSync(path.join(output, "ci-production-build.log"), log + "\n");
    const artifacts = JSON.parse(
      run("gh", ["api", `repos/across-protocol/contracts/actions/runs/${id}/artifacts`], root)
    ).artifacts;
    const artifact = artifacts.find((a: any) => a.name.startsWith("svm-artifacts-") && !a.expired);
    assert(artifact, "CI IDL artifact expired or missing");
    const dir = path.join(output, "ci-idls");
    run(
      "gh",
      ["run", "download", String(id), "--repo", "across-protocol/contracts", "--name", artifact.name, "--dir", dir],
      root
    );
    sourceIdl = path.join(dir, "src/svm/assets/idl/svm_spoke.json");
    evidence = {
      sourceCommit: meta.head_sha,
      ciRun: Number(id),
      ciJob: job.id,
      ciUrl: meta.html_url,
      binarySha256: hashes[0],
      idlSha256: sha256(readFileSync(sourceIdl)),
    };
  }
  assert.equal(
    run("git", ["diff", evidence.sourceCommit, "--", ...SOURCE_PATHS], root),
    "",
    "Program sources, dependencies or build recipe differ from the CI artifact; produce a new verified build/CI evidence"
  );
  assert.equal(
    sha256(readFileSync(sourceBinary)),
    evidence.binarySha256,
    "Local binary does not match CI's verified production binary"
  );
  assert.equal(sha256(readFileSync(sourceIdl)), evidence.idlSha256, "IDL artifact hash changed");
  const binary = path.join(output, "svm_spoke.so"),
    idl = path.join(output, "svm_spoke.json");
  copyFileSync(sourceBinary, binary);
  copyFileSync(sourceIdl, idl);
  writeFileSync(path.join(output, "spoke-artifact.json"), JSON.stringify(evidence, null, 2) + "\n");
  console.log(`Reusing CI-verified production Spoke ${evidence.binarySha256.slice(0, 12)} from run ${evidence.ciRun}`);
  return { binary, idl, evidence };
}
