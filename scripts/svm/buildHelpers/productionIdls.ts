import { Idl } from "@anchor-lang/core";
import { readFileSync } from "fs";
import path from "path";
import { strict as assert } from "assert";
import { files } from "../../../package.json";

// The npm files list is the explicit public IDL allowlist. Keep legacy assets on the same surface.
export const productionIdlNames = files
  .filter((file) => file.startsWith("/svm/idl/"))
  .map((file) => path.basename(file, ".json"));

export function readProductionIdls(directory: string): Map<string, string> {
  return new Map(
    productionIdlNames.map((name) => {
      const contents = readFileSync(path.join(directory, `${name}.json`), "utf8");
      const idl: Idl = JSON.parse(contents);
      assert.equal(idl.metadata.name, name, `Unexpected IDL at ${directory}/${name}.json`);
      for (const instruction of idl.instructions) {
        assert(!instruction.name.startsWith("test_"), `Test instruction in production IDL: ${instruction.name}`);
        for (const account of instruction.accounts) {
          if (account.name !== "event_authority" || "accounts" in account) continue;
          assert.deepEqual(
            account.pda?.seeds,
            [{ kind: "const", value: [...Buffer.from("__event_authority")] }],
            `Missing canonical event-authority PDA: ${name}.${instruction.name}`
          );
        }
      }
      if (name === "svm_spoke") {
        for (const type of ["V5AdapterInput", "AcrossDepositJitParams", "V5FillJit"])
          assert(
            idl.types?.some(({ name }) => name === type),
            `Missing V5 schema: ${type}`
          );
      }
      if (name === "message_transmitter_v2" || name === "token_messenger_minter_v2")
        assert.equal(
          contents,
          readFileSync(path.join("idls", `${name}.json`), "utf8"),
          `Unreviewed Circle IDL: ${name}`
        );
      return [name, contents];
    })
  );
}
