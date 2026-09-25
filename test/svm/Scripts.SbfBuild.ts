import { assert } from "chai";
import { spawnSync } from "child_process";
import { mkdtempSync, readdirSync, rmSync } from "fs";
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
