import { AnchorProvider, BN, Program } from "@anchor-lang/core";
import { PublicKey, Transaction, TransactionInstruction } from "@solana/web3.js";
import { expect } from "chai";
import { createHash } from "crypto";
import bs58 from "bs58";
import { SvmSpokeIdl } from "../../src/svm/assets";
import { SvmSpoke } from "../../target/types/svm_spoke";
import legacyAccount from "../svm/accounts/legacy_requested_slow_fill.json";

describe("svm_spoke verified production binary", () => {
  const provider = AnchorProvider.env();
  const program = new Program<SvmSpoke>(SvmSpokeIdl, provider);
  const [state] = PublicKey.findProgramAddressSync([Buffer.from("state"), Buffer.alloc(8)], program.programId);
  const signer = provider.wallet.publicKey;
  const initialize = (seed: BN) => program.methods.initialize(seed, 0, new BN(420), 0, signer, 3600, 14400);

  async function reject(ix: TransactionInstruction, code: number) {
    const blockhash = await provider.connection.getLatestBlockhash();
    const tx = await provider.wallet.signTransaction(new Transaction({ ...blockhash, feePayer: signer }).add(ix));
    const signature = await provider.connection.sendRawTransaction(tx.serialize(), { skipPreflight: true });
    const result = await provider.connection.confirmTransaction({ ...blockhash, signature }, "confirmed");
    expect(result.value.err).to.deep.equal({ InstructionError: [0, { Custom: code }] });
  }

  it("rejects nonzero state seeds and initializes the production state at seed zero", async () => {
    await reject(await initialize(new BN(1)).accountsPartial({ signer }).instruction(), 7014);
    await initialize(new BN(0)).accountsPartial({ signer, state }).rpc();
    const account = await program.account.state.fetch(state);
    expect(account.seed.toNumber()).to.equal(0);
    expect(account.currentTime).to.equal(0);
  });

  it("rejects clock overrides and excludes the test-only entrypoint", async () => {
    await reject(await program.methods.setCurrentTime(123).accountsPartial({ state, signer }).instruction(), 7003);
    await reject(
      new TransactionInstruction({
        programId: program.programId,
        keys: [],
        data: createHash("sha256").update("global:test_create_v5_fill_status").digest().subarray(0, 8),
      }),
      101
    );
  });

  it("uses the Clock sysvar to reclaim an expired historical fill despite stored time zero", async () => {
    const fillStatus = new PublicKey(legacyAccount.pubkey);
    const account = await program.account.fillStatusAccount.fetch(fillStatus);
    const before = await provider.connection.getBalance(account.rentRecipient);
    await program.methods
      .closeFillPda()
      .accountsPartial({ state, rentRecipient: account.rentRecipient, fillStatus })
      .rpc();
    expect(await provider.connection.getAccountInfo(fillStatus)).to.equal(null);
    expect(await provider.connection.getBalance(account.rentRecipient)).to.equal(
      before + legacyAccount.account.lamports
    );
  });

  it("emits a decodable event through the canonical signed self-CPI", async () => {
    const signature = await program.methods
      .pauseDeposits(true)
      .accountsPartial({ state, signer })
      .rpc({ commitment: "confirmed", preflightCommitment: "confirmed" });
    let tx;
    for (let attempt = 0; attempt < 20; attempt++) {
      tx = await provider.connection.getTransaction(signature, {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
      });
      if (tx) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    expect(tx?.meta?.err).to.equal(null);
    const inner = tx!.meta!.innerInstructions!.flatMap((group) => group.instructions);
    const events = inner.filter((ix) =>
      tx!.transaction.message.getAccountKeys().get(ix.programIdIndex)!.equals(program.programId)
    );
    expect(events).to.have.length(1);
    const event = program.coder.events.decode(Buffer.from(bs58.decode(events[0].data)).subarray(8).toString("base64"));
    expect(event?.name).to.equal("pausedDeposits");
    expect(event?.data.isPaused).to.equal(true);
    expect((await program.account.state.fetch(state)).pausedDeposits).to.equal(true);
  });
});
