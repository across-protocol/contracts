import { assert } from "chai";
import { spawnSync } from "child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import path from "path";

describe("SBF build diagnostic guard", () => {
  const guard = path.resolve("scripts/svm/buildHelpers/runSbfBuild.sh");

  function runBuild(script: string, args: string[] = []) {
    const work = mkdtempSync(path.join(tmpdir(), "svm-build-guard-"));
    try {
      const result = spawnSync("bash", [guard, process.execPath, "-e", script, ...args], {
        encoding: "utf8",
        env: { ...process.env, TMPDIR: work },
      });
      if (result.error) throw result.error;
      assert.deepEqual(readdirSync(work), [], "Temporary build log must be removed on success and failure");
      return result;
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }

  it("streams normal output and preserves command arguments", () => {
    const result = runBuild('console.log(process.argv[1]); console.error("warning: unused import");', [
      "arg with spaces",
    ]);
    assert.equal(result.status, 0);
    assert.include(result.stdout, "arg with spaces");
    assert.include(result.stdout, "warning: unused import");
  });

  for (const diagnostic of [
    "Error: Function example Stack offset of 4752 exceeded max offset of 4096 by 656 bytes",
    "Error: Function example Stack offset of -4752 exceeded max offset of -4096 by 656 bytes",
    "warning: stack frame size (4752) exceeds limit (4096) in function example",
    "Error: A function call in method example overwrites values in the frame. Please, decrease stack usage.",
  ]) {
    for (const stream of ["stdout", "stderr"]) {
      it(`rejects a successful compiler reporting ${diagnostic} on ${stream}`, () => {
        // Split the diagnostic across writes, as compiler output need not arrive in whole lines.
        const result = runBuild(
          `process.${stream}.write(${JSON.stringify(diagnostic.slice(0, 30))});
           setTimeout(() => process.${stream}.write(${JSON.stringify(diagnostic.slice(30))}), 10);`
        );
        assert.equal(result.status, 1);
        assert.include(result.stdout, diagnostic);
        assert.include(result.stderr, "stack-overflow diagnostics");
      });
    }
  }

  it("preserves compiler failures without stack diagnostics", () => {
    const result = runBuild('console.error("compilation failed"); process.exit(7);');
    assert.equal(result.status, 7);
    assert.include(result.stdout, "compilation failed");
  });
});

describe("Verified SBF build artifacts", () => {
  const helper = path.resolve("scripts/svm/buildHelpers/buildSolanaVerify.sh");
  const guard = path.resolve("scripts/svm/buildHelpers/runSbfBuild.sh");

  function runBuild(mode: string, isTest = false) {
    const work = mkdtempSync(path.join(tmpdir(), "svm-verified-build-"));
    try {
      for (const directory of [
        "bin",
        "programs/svm-spoke",
        "programs/mock-gateway",
        "scripts/svm/buildHelpers",
        "target/deploy",
      ]) {
        mkdirSync(path.join(work, directory), { recursive: true });
      }
      copyFileSync(guard, path.join(work, "scripts/svm/buildHelpers/runSbfBuild.sh"));
      copyFileSync(path.resolve("verified-build.json"), path.join(work, "verified-build.json"));
      writeFileSync(path.join(work, "target/deploy/svm_spoke.so"), "stale binary");
      writeFileSync(
        path.join(work, "bin/solana-verify"),
        `#!/usr/bin/env bash
set -eu
if [[ "$1" == "--version" ]]; then
  echo "solana-verify 0.5.1"
  exit 0
fi
binary="target/deploy/$3.so"
if [[ -e "$binary" ]]; then
  echo "stale artifact reached verifier" >&2
  exit 99
fi
printf '%s\\n' "$*" >> calls
case "$BUILD_MODE" in
  swallowed) echo "error: compilation failed" >&2 ;;
  empty) touch "$binary" ;;
  failure) echo partial > "$binary"; exit 7 ;;
  stack) echo partial > "$binary"; echo "Stack offset of 4752 exceeded max offset of 4096" >&2 ;;
  success) echo fresh > "$binary" ;;
esac
`,
        { mode: 0o755 }
      );
      const result = spawnSync("bash", [helper], {
        cwd: work,
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${work}/bin:${process.env.PATH}`,
          CI: "false",
          IS_TEST: String(isTest),
          BUILD_MODE: mode,
        },
      });
      if (result.error) throw result.error;
      const binary = path.join(work, "target/deploy/svm_spoke.so");
      return {
        ...result,
        binary: existsSync(binary) ? readFileSync(binary, "utf8") : undefined,
        calls: readFileSync(path.join(work, "calls"), "utf8"),
      };
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }

  for (const [mode, status] of [
    ["swallowed", 1],
    ["empty", 1],
    ["failure", 7],
    ["stack", 1],
  ] as const) {
    it(`rejects ${mode} builds and leaves no deployable output`, () => {
      const result = runBuild(mode);
      assert.equal(result.status, status, result.stdout + result.stderr);
      assert.isUndefined(result.binary);
    });
  }

  for (const isTest of [false, true]) {
    it(`accepts fresh ${isTest ? "test" : "production"} binaries with the intended programs and features`, () => {
      const result = runBuild("success", isTest);
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.equal(result.binary, "fresh\n");
      assert.include(
        result.calls,
        `--library-name svm_spoke --base-image ${JSON.parse(readFileSync("verified-build.json", "utf8")).image} --arch v0 --`
      );
      assert.equal(result.calls.includes("--library-name mock_gateway"), isTest);
      assert.equal(result.calls.includes("--features test"), isTest);
    });
  }
});
