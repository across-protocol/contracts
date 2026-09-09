const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");

const repo = resolve(__dirname, "..");
const fixture = mkdtempSync(join(tmpdir(), "foundry-toolchain-"));
const ambient = join(fixture, "bin");
const project = join(fixture, "project");
const otherRepo = join(fixture, "other-repo");
mkdirSync(ambient);
mkdirSync(project);
mkdirSync(otherRepo);

function run(command, args, cwd = repo) {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...process.env, PATH: `${ambient}:${process.env.PATH}` },
    encoding: "utf8",
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed`);
  return result.stdout;
}

try {
  // Stand-ins for another repo's installation must neither be executed by our commands nor overwritten.
  const binaries = ["forge", "cast", "anvil", "chisel", "foundryup"];
  for (const tool of binaries) {
    writeFileSync(join(ambient, tool), `#!/bin/sh\necho "${tool} from another repo"\nexit 73\n`, { mode: 0o755 });
  }
  const before = binaries.map((tool) => readFileSync(join(ambient, tool), "utf8"));
  run("yarn", ["pin-foundry"]);
  run("yarn", ["pin-foundry"]);
  run("yarn", ["check-foundry"]);
  run("yarn", ["foundry", "forge", "--version"]);
  assert.equal(run("yarn", ["foundry", "cast", "to-dec", "0x2a"]).trim().split("\n").includes("42"), true);

  mkdirSync(join(project, "src"));
  mkdirSync(join(project, "test"));
  const config = join(project, "foundry.toml");
  writeFileSync(
    config,
    '[profile.default]\nsrc = "src"\ntest = "test"\nsolc = "0.8.30"\n[profile.local-test]\nout = "out-local"\n'
  );
  writeFileSync(
    join(project, "src/Counter.sol"),
    "pragma solidity ^0.8.30; contract Counter { uint256 public n; function inc() public { n++; } }\n"
  );
  writeFileSync(
    join(project, "test/Counter.t.sol"),
    'pragma solidity ^0.8.30; import "../src/Counter.sol"; contract CounterTest { function testIncrement() public { Counter c = new Counter(); c.inc(); require(c.n() == 1); } }\n'
  );
  const args = ["--root", project, "--config-path", config];
  run("yarn", ["build-evm-foundry", ...args]);
  assert(existsSync(join(project, "out/Counter.sol/Counter.json")), "Build must emit a Solidity artifact");
  const tests = run("yarn", ["test-evm-foundry", ...args]);
  assert.match(tests, /1 passed; 0 failed/, "The smoke test must actually execute");
  assert(
    existsSync(join(project, "out-local/Counter.t.sol/CounterTest.json")),
    "Tests must use the local-test profile"
  );

  for (const [index, tool] of binaries.entries()) {
    assert.equal(readFileSync(join(ambient, tool), "utf8"), before[index], `${tool} was modified`);
  }
  const outside = spawnSync("forge", ["--version"], {
    cwd: otherRepo,
    env: { ...process.env, PATH: `${ambient}:${process.env.PATH}` },
    encoding: "utf8",
  });
  assert.equal(outside.status, 73);
  assert.match(outside.stdout, /forge from another repo/);
  console.log("Toolchain install, build and test passed; the other repo's tools remain unchanged.");
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
