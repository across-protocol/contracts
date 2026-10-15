import { BN, Program, utils } from "@anchor-lang/core";
import { Connection, MessageV0, PublicKey, VersionedTransactionResponse } from "@solana/web3.js";
import { assert } from "chai";
import { ethers } from "ethers";
import { SvmSpokeAnchor, SvmSpokeIdl } from "../../src/svm/assets";
import { decodeCpiEvents, readEventsForAddress, readFillEventFromFillStatusPda } from "../../scripts/svm/utils/events";
import { inspectFillStatus } from "../../scripts/svm/findFillStatusFromFillStatusPda";
import { queryEvents } from "../../scripts/svm/queryEventsV2";

describe("Internal event query scripts", () => {
  const connection = new Connection("http://127.0.0.1:8899");
  // Exercise an explicit deployment rather than Anchor's workspace program address.
  const program = new Program({ ...SvmSpokeIdl, address: PublicKey.default.toBase58() }, { connection });
  const [authority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId);
  const chainId = new BN(99);
  // Independent relay-hash preimage: 280 zero bytes for the relay fields/message hash, then destination chain ID.
  const relayHash = Buffer.from(
    ethers.utils.keccak256(Buffer.concat([Buffer.alloc(280), chainId.toArrayLike(Buffer, "le", 8)])).slice(2),
    "hex"
  );
  const [pda] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId);
  const prefix = Buffer.from("e445a52e51cb9a1d", "hex");
  // Frozen historical event discriminators/layouts, independent of the decoder under test.
  const fill = Buffer.concat([prefix, Buffer.from([25, 58, 182, 0, 50, 99, 160, 117]), Buffer.alloc(393)]);
  const request = Buffer.concat([prefix, Buffer.from([221, 123, 11, 14, 71, 37, 178, 167]), Buffer.alloc(280)]);
  const otherFill = Buffer.from(fill);
  otherFill[16] = 1; // Different input token, so a different relay/PDA despite sharing the transaction.
  function receipt(data: Buffer | Buffer[] = fill): VersionedTransactionResponse {
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
          {
            index: 0,
            instructions: (Array.isArray(data) ? data : [data]).map((bytes) => ({
              programIdIndex: 0,
              accounts: [2],
              data: utils.bytes.bs58.encode(bytes),
            })),
          },
        ],
      },
    };
  }

  function historyRpc(transactions: Record<string, VersionedTransactionResponse | null>): Connection {
    return {
      getSignaturesForAddress: async () => Object.keys(transactions).map((signature) => ({ signature, err: null })),
      getTransaction: async (signature: string) => transactions[signature],
    } as unknown as Connection;
  }

  async function captureOutput(run: (logs: string[], warnings: string[]) => Promise<void>) {
    const logs: string[] = [];
    const warnings: string[] = [];
    const { log, warn } = console;
    console.log = (...args) => logs.push(args.join(" "));
    console.warn = (...args) => warnings.push(args.join(" "));
    try {
      await run(logs, warnings);
    } finally {
      console.log = log;
      console.warn = warn;
    }
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
        return receipt(signature === "closed" ? [] : signature === "requested" ? request : fill);
      },
    } as unknown as Connection;
    const event = await readFillEventFromFillStatusPda(rpc, program, pda, chainId);
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
    assert.isNull(await readFillEventFromFillStatusPda(rpc, program, pda, chainId));
    assert.deepEqual(cursors, [undefined, "999"]);
  });

  it("matches the requested relay within a batch after a newer unrelated fill referencing the same PDA", async () => {
    const rpc = historyRpc({ unrelated: receipt(otherFill), batch: receipt([otherFill, fill]) });
    const event = await readFillEventFromFillStatusPda(rpc, program, pda, chainId);
    assert.equal(event?.signature, "batch");
    assert.isTrue((event?.data.inputToken as PublicKey).equals(PublicKey.default));
    // Repayment chain ID is zero in the frozen event; only the destination chain ID derives the requested PDA.
    assert.isNull(await readFillEventFromFillStatusPda(rpc, program, pda, new BN(0)));
    assert.isNull(
      await readFillEventFromFillStatusPda(historyRpc({ unrelated: receipt(otherFill) }), program, pda, chainId)
    );
  });

  it("warns for missing receipts/metadata and can still find an exact fill in available history", async () => {
    await captureOutput(async (_logs, warnings) => {
      const noMeta = receipt();
      noMeta.meta = null;
      const rpc = historyRpc({ pruned: null, noMeta, filled: receipt() });
      assert.equal((await readFillEventFromFillStatusPda(rpc, program, pda, chainId))?.signature, "filled");
      assert.lengthOf(warnings, 2);
      assert.include(warnings[0], "Incomplete history: transaction pruned");
      assert.include(warnings[1], "Incomplete history: transaction noMeta");
    });
  });

  function inspectionProgram(rpc: Connection, present: boolean): Program<SvmSpokeAnchor> {
    const seed = new BN(7);
    const [state] = PublicKey.findProgramAddressSync(
      [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)],
      program.programId
    );
    return {
      programId: program.programId,
      coder: program.coder,
      provider: { connection: rpc },
      account: {
        state: {
          fetch: async (address: PublicKey, commitment: string) => {
            assert.isTrue(address.equals(state));
            assert.equal(commitment, "confirmed");
            return { chainId };
          },
        },
        fillStatusAccount: {
          fetchNullable: async (address: PublicKey, commitment: string) => {
            assert.isTrue(address.equals(pda));
            assert.equal(commitment, "confirmed");
            return present ? { status: { filled: {} } } : null;
          },
        },
      },
    } as unknown as Program<SvmSpokeAnchor>;
  }

  for (const present of [true, false]) {
    it(`reports ${present ? "current status" : "account absence"} without claiming closure when history is unavailable`, async () => {
      await captureOutput(async (logs, warnings) => {
        const rpc = historyRpc({ pruned: null });
        await inspectFillStatus(inspectionProgram(rpc, present), pda, new BN(7));
        assert.equal(logs[0], `fillStatus ${present ? "filled" : "account not found"}`);
        assert.include(logs, "No matching fill event found in available history.");
        assert.isFalse(logs.some((line) => line.includes("closed")));
        assert.lengthOf(warnings, 1);
      });
    });
  }

  it("reports closure only with a matching historical event and includes its signature/slot", async () => {
    await captureOutput(async (logs) => {
      await inspectFillStatus(inspectionProgram(historyRpc({ filled: receipt() }), false), pda, new BN(7));
      assert.include(logs, "Historical fill found; fill-status account has since been closed.");
      assert.include(logs, "signature filled");
      assert.include(logs, "slot 42");
    });
  });

  it("prints current status before propagating a history RPC failure", async () => {
    await captureOutput(async (logs) => {
      const rpc = {
        getSignaturesForAddress: async () => {
          throw new Error("RPC unavailable");
        },
      } as unknown as Connection;
      try {
        await inspectFillStatus(inspectionProgram(rpc, true), pda, new BN(7));
        assert.fail("Expected RPC failure");
      } catch (error) {
        assert.equal((error as Error).message, "RPC unavailable");
      }
      assert.equal(logs[0], "fillStatus filled");
    });
  });

  it("streams filtered JSONL before the next receipt is fetched, with signature and slot", async () => {
    await captureOutput(async (logs) => {
      const rpc = historyRpc({ requested: receipt(request), first: receipt(), second: receipt() });
      const getTransaction = rpc.getTransaction.bind(rpc);
      rpc.getTransaction = (async (signature: string) => {
        if (signature === "second") {
          assert.lengthOf(logs, 1);
          assert.include(JSON.parse(logs[0]), { name: "filledRelay", signature: "first", slot: 42 });
        }
        return getTransaction(signature);
      }) as typeof rpc.getTransaction;
      const selected = new Program({ ...SvmSpokeIdl, address: program.programId.toBase58() }, { connection: rpc });
      await queryEvents(selected, "FilledRelay", true);
      assert.lengthOf(logs, 2);
      assert.equal(JSON.parse(logs[1]).signature, "second");
    });
  });

  it("preserves the default JSON-array output without adding a metadata wrapper", async () => {
    await captureOutput(async (logs) => {
      const rpc = historyRpc({ requested: receipt(request), filled: receipt() });
      const selected = new Program({ ...SvmSpokeIdl, address: program.programId.toBase58() }, { connection: rpc });
      await queryEvents(selected, "FilledRelay", false);
      assert.lengthOf(logs, 1);
      const events = JSON.parse(logs[0]);
      assert.lengthOf(events, 1);
      assert.property(events[0], "inputToken");
      assert.notProperty(events[0], "signature");
    });
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
