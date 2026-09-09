const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");

const pin = readFileSync(join(__dirname, "../.tool-versions"), "utf8").match(/^foundry\s+(\S+)\s*$/m)?.[1];
assert(pin, "Expected an exact Foundry version in .tool-versions");
for (const tool of ["forge", "cast", "anvil", "chisel"]) {
  const version = execFileSync(tool, ["--version"], { encoding: "utf8" }).match(/Version:\s+(\S+)/)?.[1];
  assert.equal(version, pin, `${tool} must match .tool-versions; run yarn pin-foundry`);
  console.log(`${tool}: ${version}`);
}
