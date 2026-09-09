const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");

const zksync = process.argv.includes("--zksync");
const config = zksync ? "mise.zksync.toml" : ".tool-versions";
const pin = readFileSync(join(__dirname, "..", config), "utf8").match(
  zksync ? /^version = "([^"]+)"$/m : /^foundry\s+(\S+)\s*$/m
)?.[1];
assert(pin, `Expected an exact Foundry version in ${config}`);
for (const tool of zksync ? ["forge", "cast"] : ["forge", "cast", "anvil", "chisel"]) {
  const version = execFileSync(tool, ["--version"], { encoding: "utf8" }).match(/Version:\s+(\S+)/)?.[1];
  const actual = zksync ? version?.split("-foundry-zksync-v")[1] : version;
  assert.equal(actual, pin, `${tool} must match ${config}; run yarn pin-foundry${zksync ? "-zksync" : ""}`);
  console.log(`${tool}: ${version}`);
}
