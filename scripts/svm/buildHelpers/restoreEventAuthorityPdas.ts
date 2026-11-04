import { Idl } from "@anchor-lang/core";
import { execFileSync } from "child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "fs";
import path from "path";

// Anchor 1.1 validates event authority against a compile-time constant. Its IDL
// omits the equivalent PDA seeds, breaking typed account resolution and Codama's
// async builders. Restore the canonical Anchor seed as client-only metadata.
for (const directory of readdirSync("programs")) {
  const file = `${directory.replace(/-/g, "_")}.json`;
  const idlPath = path.join("target/idl", file);
  if (!existsSync(idlPath)) continue;
  const idl: Idl = JSON.parse(readFileSync(idlPath, "utf8"));
  let changed = false;
  for (const instruction of idl.instructions) {
    const accounts = instruction.accounts;
    const authority = accounts[accounts.length - 2];
    const program = accounts[accounts.length - 1];
    if (
      authority?.name === "event_authority" &&
      program?.name === "program" &&
      !("accounts" in authority) &&
      !authority.pda &&
      !authority.address
    ) {
      authority.pda = { seeds: [{ kind: "const", value: [...Buffer.from("__event_authority")] }] };
      changed = true;
    }
  }
  if (!changed) continue;
  writeFileSync(idlPath, JSON.stringify(idl, null, 2) + "\n");
  execFileSync("anchor", ["idl", "type", "--out", path.join("target/types", file.replace(/\.json$/, ".ts")), idlPath], {
    stdio: "inherit",
  });
}
