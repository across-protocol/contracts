const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, symlinkSync } = require("node:fs");
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

function run(command, args, cwd = repo, input) {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...process.env, PATH: `${ambient}:${process.env.PATH}` },
    encoding: "utf8",
    input,
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

  run(
    "bash",
    [
      "-euc",
      'source "$1"; test "$PWD" -ef "$3"; test "$4" = "argument with spaces"; read -r line; test "$line" = "preserved input"; "$5" "$2"',
      "bash",
      join(repo, "scripts/setupFoundryEnv.sh"),
      join(repo, "scripts/checkFoundryVersion.js"),
      otherRepo,
      "argument with spaces",
      process.execPath,
    ],
    otherRepo,
    "preserved input\n"
  );
  run("bash", [join(repo, "script/mintburn/checkSponsoredPeripheryProdReadiness.sh"), "--help"], otherRepo);

  // Pin lookup must handle an unrelated version first and the inline TOML form.
  mkdirSync(join(project, "scripts"));
  const checker = join(project, "scripts/checkFoundryVersion.js");
  writeFileSync(checker, readFileSync(join(repo, "scripts/checkFoundryVersion.js")));
  const pin = run("mise", ["current", "foundry"]).trim();
  writeFileSync(join(project, "mise.toml"), `[tools.node]\nversion = "22.18.0"\n[tools]\nfoundry = "${pin}"\n`);
  run("mise", ["trust", join(project, "mise.toml")]);
  run("yarn", ["foundry", "node", checker]);

  const missing = join(fixture, "missing-foundry");
  mkdirSync(missing);
  symlinkSync(run("bash", ["-c", "command -v mise"]).trim(), join(missing, "mise"));
  const absent = spawnSync(process.execPath, [checker], {
    cwd: project,
    env: { ...process.env, PATH: missing },
    encoding: "utf8",
  });
  assert.equal(absent.status, 1);
  assert.match(absent.stderr, /forge ENOENT/);
  assert.match(absent.stderr, /Run yarn pin-foundry/);

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

  if (process.argv.includes("--zksync")) {
    run("yarn", ["pin-foundry-zksync"]);
    run("yarn", ["pin-foundry-zksync"]);
    run("yarn", ["check-foundry-zksync"]);
    const repoConfig = readFileSync(join(repo, "foundry.toml"), "utf8");
    const solc = repoConfig.match(/^solc = "([^"]+)"$/m)[1];
    const zksolc = repoConfig.match(/^zksolc = "([^"]+)"$/m)[1];
    writeFileSync(
      config,
      `[profile.default]\nsrc = "src"\ntest = "test"\nsolc = "${solc}"\n[profile.zksync.zksync]\ncompile = true\nzksolc = "${zksolc}"\n`
    );
    // --skip test/script only excludes .t.sol/.s.sol; ordinary EVM helpers must also be excluded.
    mkdirSync(join(project, "script"));
    for (const dir of ["test", "script"]) {
      writeFileSync(
        join(project, dir, "EvmOnlyHelper.sol"),
        'pragma solidity ^0.8.30; import "../src/Counter.sol"; contract EvmOnlyHelper { function code() external pure returns (bytes memory) { return type(Counter).runtimeCode; } }\n'
      );
    }
    for (const suffix of ["t", "s"]) {
      writeFileSync(
        join(project, `src/EvmOnly.${suffix}.sol`),
        'pragma solidity ^0.8.30; import "./Counter.sol"; contract EvmOnly { function code() external pure returns (bytes memory) { return type(Counter).runtimeCode; } }\n'
      );
    }
    run("yarn", ["forge-build-zksync", ...args]);
    assert(existsSync(join(project, "zkout/Counter.sol/Counter.json")), "zkSync must emit an EraVM artifact");
    // Exercise deployment/verification command selection without sending any transactions.
    run("yarn", ["forge-script-zksync", "--help"]);
    run("yarn", ["forge-verify-zksync", "--help"]);
    run("yarn", ["check-foundry"]);
    run("yarn", ["foundry-zksync", "forge", "--version"]);
    run("yarn", ["check-foundry"]);
  }

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
