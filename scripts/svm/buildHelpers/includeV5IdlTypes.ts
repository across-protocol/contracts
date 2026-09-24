import { Idl } from "@coral-xyz/anchor";
import { execFileSync } from "child_process";
import { readFileSync, writeFileSync } from "fs";
import { isDeepStrictEqual } from "util";

// Anchor only discovers types reachable from instruction signatures/accounts/events. V5FillJit travels
// inside Vec<u8>, so include its Rust-derived schema and dependencies before generating public clients.
const idlPath = "target/idl/svm_spoke.json";
const idl: Idl = JSON.parse(readFileSync(idlPath, "utf8"));
const types: NonNullable<Idl["types"]> = JSON.parse(
  execFileSync("cargo", ["run", "--quiet", "-p", "svm-spoke", "--bin", "export_v5_types", "--features", "idl-build"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }),
  // Match Anchor's unqualified IDL names for both definitions and references; reject collisions below.
  (key, value) => (key === "name" && typeof value === "string" ? value.split("::").pop() : value)
);
idl.types ??= [];
for (const type of types) {
  const existing = idl.types.find(({ name }) => name === type.name);
  if (existing && !isDeepStrictEqual(existing, type)) throw new Error(`Conflicting IDL type: ${type.name}`);
  if (!existing) idl.types.push(type);
}
idl.types.sort((a, b) => a.name.localeCompare(b.name));
writeFileSync(idlPath, JSON.stringify(idl, null, 2) + "\n");
execFileSync("anchor", ["idl", "type", "--out", "target/types/svm_spoke.ts", idlPath], { stdio: "inherit" });
