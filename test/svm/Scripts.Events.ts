import { Program, utils } from "@anchor-lang/core";
import { Connection, MessageV0, PublicKey, VersionedTransactionResponse } from "@solana/web3.js";
import { assert } from "chai";
import { SvmSpokeIdl } from "../../src/svm/assets";
import { decodeCpiEvents, readEventsForAddress, readFillEventFromFillStatusPda } from "../../scripts/svm/utils/events";

describe("Internal event query scripts", () => {
  const connection = new Connection("http://127.0.0.1:8899");
  // Exercise an explicit deployment rather than Anchor's workspace program address.
  const program = new Program({ ...SvmSpokeIdl, address: PublicKey.default.toBase58() }, { connection });
  const [authority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId);
  const pda = new PublicKey(Buffer.alloc(32, 7));
  const prefix = Buffer.from("e445a52e51cb9a1d", "hex");
  // Frozen historical event discriminators/layouts, independent of the decoder under test.
  const fill = Buffer.concat([prefix, Buffer.from([25, 58, 182, 0, 50, 99, 160, 117]), Buffer.alloc(393)]);
  const request = Buffer.concat([prefix, Buffer.from([221, 123, 11, 14, 71, 37, 178, 167]), Buffer.alloc(280)]);
  function receipt(data = fill): VersionedTransactionResponse {
    return {
      slot: 42,
      version: 0,
      transaction: {
        signatures: [],
        message: new MessageV0({
          header: { numRequiredSignatures: 0, numReadonlySignedAccounts: 0, numReadonlyUnsignedAccounts: 1 },
          staticAccountKeys: [program.programId],
          recentBlockhash: PublicKey.default.toBase58(),
          compiledInstructions: [],
          addressTableLookups: [{ accountKey: pda, writableIndexes: [0], readonlyIndexes: [1] }],
        }),
      },
      meta: {
        err: null,
        fee: 0,
        preBalances: [],
        postBalances: [],
        loadedAddresses: { writable: [pda], readonly: [authority] },
        innerInstructions: [
          { index: 0, instructions: [{ programIdIndex: 0, accounts: [2], data: utils.bytes.bs58.encode(data) }] },
        ],
      },
    };
  }

  it("decodes canonical CPI events with lookup-table accounts for the selected program", () => {
    assert.equal(decodeCpiEvents(receipt(), program)[0].name, "filledRelay");
    assert.equal(decodeCpiEvents(receipt(request), program)[0].name, "requestedSlowFill");
  });

  it("ignores failed transactions, wrong programs/authorities, forged prefixes and malformed payloads", () => {
    const failed = receipt();
    failed.meta!.err = { InstructionError: [0, { Custom: 1 }] };
    const wrongProgram = receipt();
    wrongProgram.meta!.innerInstructions![0].instructions[0].programIdIndex = 1;
    const wrongAuthority = receipt();
    wrongAuthority.meta!.innerInstructions![0].instructions[0].accounts = [1];
    const extraAccount = receipt();
    extraAccount.meta!.innerInstructions![0].instructions[0].accounts = [2, 1];
    for (const tx of [
      failed,
      wrongProgram,
      wrongAuthority,
      extraAccount,
      receipt(Buffer.concat([Buffer.alloc(8), fill.subarray(8)])),
      receipt(fill.subarray(0, 20)),
      receipt(Buffer.alloc(0)),
    ])
      assert.deepEqual(decodeCpiEvents(tx, program), []);
  });

  it("searches past closures, requests and failed fills instead of assuming the oldest signature is a fill", async () => {
    const signatures = ["closed", "failed", "requested", "filled", "spam"];
    const queried: string[] = [];
    const rpc = {
      getSignaturesForAddress: async (address: PublicKey) => {
        assert.isTrue(address.equals(pda));
        return signatures.map((signature) => ({ signature, err: signature === "failed" ? { failure: true } : null }));
      },
      getTransaction: async (signature: string) => {
        queried.push(signature);
        return signature === "closed" ? null : receipt(signature === "requested" ? request : fill);
      },
    } as unknown as Connection;
    const event = await readFillEventFromFillStatusPda(rpc, program, pda);
    assert.equal(event?.signature, "filled");
    assert.equal(event?.slot, 42);
    assert.deepEqual(queried, ["closed", "requested", "filled"]);
  });

  it("paginates full history, terminates on an empty page, and returns no invented fill", async () => {
    const cursors: (string | undefined)[] = [];
    const rpc = {
      getSignaturesForAddress: async (_address: PublicKey, options: { before?: string }) => {
        cursors.push(options.before);
        return options.before ? [] : Array.from({ length: 1000 }, (_, i) => ({ signature: String(i), err: {} }));
      },
    } as unknown as Connection;
    assert.isNull(await readFillEventFromFillStatusPda(rpc, program, pda));
    assert.deepEqual(cursors, [undefined, "999"]);
  });

  it("propagates RPC errors instead of reporting a missing or filled account", async () => {
    const rpc = {
      getSignaturesForAddress: async () => {
        throw new Error("RPC unavailable");
      },
    } as unknown as Connection;
    try {
      for await (const _event of readEventsForAddress(rpc, program, pda)) assert.fail("Unexpected event");
      assert.fail("Expected RPC failure");
    } catch (error) {
      assert.equal((error as Error).message, "RPC unavailable");
    }
  });
});
