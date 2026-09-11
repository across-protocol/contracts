import { rejects } from "assert";
import { AnchorProvider, Wallet } from "@coral-xyz/anchor";
import { Connection, Keypair, PublicKey } from "@solana/web3.js";
import { assert } from "chai";
import { fetchCctpV2Messages, finalizeCctpV2Messages } from "../../scripts/svm/utils/cctpV2";
import { encodeMessageHeaderV2 } from "../../src/svm/web3-v1/cctpV2Helpers";
import { getSpokePoolProgram, getTokenMessengerMinterV2Program } from "../../src/svm/web3-v1/programConnectors";

describe("CCTP V2 script attestations", () => {
  const txHash = `0x${"ab".repeat(32)}`;
  const iris = "https://iris.invalid";
  const originalFetch = globalThis.fetch;
  const complete = {
    message: `0x${"01".repeat(152)}`,
    attestation: "0x1234",
    eventNonce: "1",
    cctpVersion: 2,
    status: "complete",
  };

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("returns all completed V2 messages and excludes V1 messages", async () => {
    globalThis.fetch = async (url) => {
      assert.equal(url, `${iris}/v2/messages/0?transactionHash=${txHash}`);
      return Response.json({ messages: [complete, { ...complete, cctpVersion: 1 }, { ...complete, eventNonce: "2" }] });
    };
    const messages = await fetchCctpV2Messages(txHash, 0, iris);
    assert.lengthOf(messages, 2);
    assert.equal(messages[0].message.toString("hex"), complete.message.slice(2));
    assert.equal(messages[0].attestation.toString("hex"), "1234");
  });

  it("accepts tokenless responses with empty decoded metadata", async () => {
    globalThis.fetch = async () => Response.json({ messages: [{ ...complete, decodedMessage: {} }] });
    assert.lengthOf(await fetchCctpV2Messages(txHash, 0, iris), 1);
  });

  it("ignores decoded metadata thresholds and still validates consumed response fields", async () => {
    globalThis.fetch = async () =>
      Response.json({
        messages: [
          {
            ...complete,
            decodedMessage: { minFinalityThreshold: "1500", finalityThresholdExecuted: "2500" },
            extraMetadata: true,
          },
        ],
      });
    assert.lengthOf(await fetchCctpV2Messages(txHash, 0, iris), 1);
    globalThis.fetch = async () => Response.json({ messages: [{ ...complete, message: 123 }] });
    await rejects(fetchCctpV2Messages(txHash, 0, iris), /message/);
  });

  it("requires nonce selection for multiple spoke messages and rejects unmatched selections", async () => {
    // An unreachable RPC proves that selection errors happen before any submission or account read.
    const provider = new AnchorProvider(new Connection("http://127.0.0.1:1"), new Wallet(Keypair.generate()), {});
    const program = getSpokePoolProgram(provider, { network: "mainnet" });
    const messages = [1n, 2n].map((nonce) => ({
      ...complete,
      message: `0x${encodeMessageHeaderV2({
        version: 1,
        sourceDomain: 0,
        destinationDomain: 5,
        nonce,
        sender: PublicKey.default,
        recipient: program.programId,
        destinationCaller: PublicKey.default,
        minFinalityThreshold: 2000,
        finalityThresholdExecuted: 2000,
        messageBody: Buffer.alloc(4),
      }).toString("hex")}`,
    }));
    globalThis.fetch = async () => Response.json({ messages });
    await rejects(finalizeCctpV2Messages(provider, program, PublicKey.default, txHash, 0, iris), /Nonces: 1, 2/);
    await rejects(
      finalizeCctpV2Messages(provider, program, PublicKey.default, txHash, 0, iris, 1000, "3"),
      /No matching/
    );
    const tokenProgram = getTokenMessengerMinterV2Program(provider, { network: "mainnet" });
    const tokenMessage = Buffer.from(messages[1].message.slice(2), "hex");
    tokenProgram.programId.toBuffer().copy(tokenMessage, 76);
    globalThis.fetch = async () =>
      Response.json({ messages: [messages[0], { ...messages[1], message: `0x${tokenMessage.toString("hex")}` }] });
    await rejects(
      finalizeCctpV2Messages(provider, program, PublicKey.default, txHash, 0, iris, 1000, undefined, {
        program: tokenProgram,
      }),
      /Nonces: 1, 2/
    );
    await rejects(
      finalizeCctpV2Messages(provider, program, PublicKey.default, txHash, 0, iris, 1000, "2"),
      /No matching/
    );
    globalThis.fetch = async () =>
      Response.json({
        messages: [
          {
            ...messages[0],
            message: `0x${encodeMessageHeaderV2({
              version: 1,
              sourceDomain: 0,
              destinationDomain: 5,
              nonce: 1n,
              sender: PublicKey.default,
              recipient: PublicKey.default,
              destinationCaller: PublicKey.default,
              minFinalityThreshold: 2000,
              finalityThresholdExecuted: 2000,
              messageBody: Buffer.alloc(4),
            }).toString("hex")}`,
          },
        ],
      });
    await rejects(finalizeCctpV2Messages(provider, program, PublicKey.default, txHash, 0, iris), /No matching/);
  });

  it("polls through not-indexed and pending responses before returning an attestation", async function () {
    this.timeout(10_000);
    const responses = [
      new Response(null, { status: 404 }),
      Response.json({
        messages: [{ ...complete, message: "0x", attestation: "PENDING", status: "pending_confirmations" }],
      }),
      Response.json({ messages: [complete] }),
    ];
    globalThis.fetch = async () => responses.shift()!;
    assert.lengthOf(await fetchCctpV2Messages(txHash, 0, iris), 1);
    assert.isEmpty(responses);
  });

  for (const status of [404, 429, 503]) {
    it(`times out recoverably while Iris returns HTTP ${status}`, async () => {
      globalThis.fetch = async () => new Response(null, { status });
      await rejects(fetchCctpV2Messages(txHash, 0, iris, 10), /rerun with the same source transaction/);
    });
  }

  it("fails immediately on nonretryable HTTP errors", async () => {
    globalThis.fetch = async () => new Response(null, { status: 400 });
    await rejects(fetchCctpV2Messages(txHash, 0, iris), /HTTP 400/);
  });

  it("rejects V1-only transactions and malformed completed attestations", async () => {
    globalThis.fetch = async () => Response.json({ messages: [{ ...complete, cctpVersion: 1 }] });
    await rejects(fetchCctpV2Messages(txHash, 0, iris), /no CCTP V2 messages/);
    globalThis.fetch = async () => Response.json({ messages: [{ ...complete, attestation: "PENDING" }] });
    await rejects(fetchCctpV2Messages(txHash, 0, iris), /Invalid completed/);
  });

  it("validates the request before contacting Iris", async () => {
    globalThis.fetch = async () => {
      throw new Error("Unexpected request");
    };
    await rejects(fetchCctpV2Messages("invalid", 0, iris), /transaction hash/);
    await rejects(fetchCctpV2Messages(txHash, -1, iris), /source domain/);
    await rejects(fetchCctpV2Messages(txHash, 0, iris, 0), /Timeout/);
  });
});
