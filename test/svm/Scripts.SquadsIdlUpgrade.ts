import { assert } from "chai";
import { spawnSync } from "child_process";
import { Keypair, Message, PublicKey, Transaction } from "@solana/web3.js";
import bs58 from "bs58";

describe("Legacy Squads IDL exports", () => {
  const [program, vault, recipient, buffer] = Array.from({ length: 4 }, () => Keypair.generate().publicKey);
  let idl: PublicKey;

  before(async () => {
    idl = await PublicKey.createWithSeed(PublicKey.findProgramAddressSync([], program)[0], "anchor:idl", program);
  });

  function run(args: string[]) {
    const result = spawnSync(
      process.execPath,
      [
        "-r",
        "ts-node/register/transpile-only",
        "scripts/svm/squadsIdlUpgrade.ts",
        "--programId",
        program.toBase58(),
        "--multisig",
        vault.toBase58(),
        "--closeRecipient",
        recipient.toBase58(),
        ...args,
      ],
      { encoding: "utf8" }
    );
    if (result.error) throw result.error;
    return result;
  }

  function instructions(args: string[]) {
    const result = run(args);
    assert.equal(result.status, 0, result.stderr);
    const message = result.stdout.trim().split("\n").pop()!;
    return Transaction.populate(Message.from(bs58.decode(message))).instructions;
  }

  it("exports only canonical IDL closure, with the vault signer and selected rent recipient", () => {
    const ixs = instructions(["--closeIdl"]);
    assert.lengthOf(ixs, 1);
    assert.equal(ixs[0].programId.toBase58(), program.toBase58());
    // Anchor 0.31.1 IDL_IX_TAG in little endian, followed by IdlInstruction::Close (5).
    assert.equal(ixs[0].data.toString("hex"), "40f4bc78a7e9690a05");
    assert.deepEqual(
      ixs[0].keys.map((key) => key.pubkey.toBase58()),
      [idl, vault, recipient].map(String)
    );
    assert.isTrue(ixs[0].keys[0].isWritable);
    assert.isTrue(ixs[0].keys[1].isSigner);
    assert.isTrue(ixs[0].keys[2].isWritable);
  });

  it("preserves the existing buffer update followed by buffer closure", () => {
    const ixs = instructions(["--idlBuffer", buffer.toBase58()]);
    assert.lengthOf(ixs, 2);
    assert.equal(ixs[0].data.toString("hex"), "40f4bc78a7e9690a03");
    assert.deepEqual(
      ixs[0].keys.map((key) => key.pubkey.toBase58()),
      [buffer, idl, vault].map(String)
    );
    assert.equal(ixs[1].data.toString("hex"), "40f4bc78a7e9690a05");
    assert.deepEqual(
      ixs[1].keys.map((key) => key.pubkey.toBase58()),
      [buffer, vault, recipient].map(String)
    );
  });

  for (const args of [[], ["--closeIdl", "--idlBuffer", buffer.toBase58()]]) {
    it(`rejects an ambiguous operation: ${args.join(" ") || "no mode"}`, () => {
      const result = run(args);
      assert.notEqual(result.status, 0);
      assert.include(result.stderr, "Supply either --idlBuffer or --closeIdl, not both");
      assert.notInclude(result.stdout, "import it into the multisig");
    });
  }
});
