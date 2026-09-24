const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { join } = require("node:path");

const zksync = process.argv.includes("--zksync");
const config = zksync ? "mise.zksync.toml" : "mise.toml";
try {
  const pin = execFileSync(
    "mise",
    [
      "-C",
      join(__dirname, ".."),
      ...(zksync ? ["-E", "zksync"] : []),
      "current",
      zksync ? "github:matter-labs/foundry-zksync" : "foundry",
    ],
    { encoding: "utf8" }
  ).trim();
  assert(pin, `Expected an exact Foundry version in ${config}`);
  for (const tool of zksync ? ["forge", "cast"] : ["forge", "cast", "anvil", "chisel"]) {
    const version = execFileSync(tool, ["--version"], { encoding: "utf8" }).match(/Version:\s+(\S+)/)?.[1];
    const actual = zksync ? version?.split("-foundry-zksync-v")[1] : version;
    assert.equal(actual, pin, `${tool} must match ${config}`);
    console.log(`${tool}: ${version}`);
  }
} catch (error) {
  console.error(
    `${error.message}\nRun yarn pin-foundry${zksync ? "-zksync" : ""} to install and select the pinned tools.`
  );
  process.exitCode = 1;
}
