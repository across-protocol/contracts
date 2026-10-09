import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

const root = path.resolve(__dirname, "../../..");
// Asset generation scans these directories; remove V1 leftovers before it can re-export them.
for (const name of ["message_transmitter", "token_messenger_minter"]) {
  for (const [directory, extension] of [
    ["target/idl", "json"],
    ["target/types", "ts"],
    ["src/svm/assets/idl", "json"],
    ["src/svm/assets", "ts"],
  ])
    fs.rmSync(path.join(root, directory, `${name}.${extension}`), { force: true });
}
for (const directory of ["target/idl", "target/types"]) fs.mkdirSync(path.join(root, directory), { recursive: true });

// Use reviewed Circle snapshots. Their legacy on-chain IDL storage does not require a second Anchor client.
// Update the snapshots explicitly when adopting a Circle interface change.
for (const name of ["message_transmitter_v2", "token_messenger_minter_v2"]) {
  const idl = path.join(root, "target/idl", `${name}.json`);
  fs.copyFileSync(path.join(root, "idls", `${name}.json`), idl);
  execFileSync("anchor", ["idl", "type", "--out", path.join(root, "target/types", `${name}.ts`), idl], {
    stdio: "inherit",
  });
}
