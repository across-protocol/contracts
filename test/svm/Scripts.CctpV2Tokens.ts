import { rejects } from "assert";
import { AnchorProvider, Wallet, workspace } from "@coral-xyz/anchor";
import { Keypair, PublicKey } from "@solana/web3.js";
import { createMint, getAccount, getOrCreateAssociatedTokenAccount, mintTo } from "@solana/spl-token";
import { assert } from "chai";
import { encodeMessageHeaderV2 } from "../../src/svm/web3-v1/cctpV2Helpers";
import {
  getMessageTransmitterV2Program,
  getTokenMessengerMinterV2Program,
} from "../../src/svm/web3-v1/programConnectors";
import { receiveCctpV2Tokens } from "../../scripts/svm/utils/cctpV2";

// The local validator uses Circle's programs with signature threshold 0 and the test wallet as token controller.
describe("CCTP V2 script token delivery", () => {
  const provider = AnchorProvider.env();
  const payer = (provider.wallet as Wallet).payer;
  const connection = provider.connection;
  const program = workspace.TokenMessengerMinterV2 as ReturnType<typeof getTokenMessengerMinterV2Program>;
  const transmitter = workspace.MessageTransmitterV2 as ReturnType<typeof getMessageTransmitterV2Program>;
  const state = Keypair.generate().publicKey;
  const remoteToken = Keypair.generate().publicKey;
  const pda = (name: string, ...seeds: Buffer[]) =>
    PublicKey.findProgramAddressSync([Buffer.from(name), ...seeds], program.programId)[0];
  let mint: PublicKey, vault: PublicKey, feeAta: PublicKey, sender: PublicKey;
  let nonce = BigInt(Date.now());
  const buildMessage = (threshold: number, recipient = vault, wrongSender = false) => {
    const body = Buffer.alloc(228);
    body.writeUInt32BE(1);
    remoteToken.toBuffer().copy(body, 4);
    recipient.toBuffer().copy(body, 36);
    body.writeBigUInt64BE(1000n, 92); // amount u256, offset 68
    body.writeBigUInt64BE(10n, 156); // maxFee u256, offset 132
    body.writeBigUInt64BE(10n, 188); // feeExecuted u256, offset 164
    return encodeMessageHeaderV2({
      version: 1,
      sourceDomain: 0,
      destinationDomain: 5,
      nonce: ++nonce,
      sender: wrongSender ? PublicKey.default : sender,
      recipient: program.programId,
      destinationCaller: PublicKey.default,
      minFinalityThreshold: threshold,
      finalityThresholdExecuted: threshold,
      messageBody: body,
    });
  };
  const deliver = (message: Buffer, recipient?: PublicKey) =>
    receiveCctpV2Tokens(provider, program, state, message, Buffer.alloc(0), recipient, transmitter);

  before(async () => {
    mint = await createMint(connection, payer, payer.publicKey, null, 6, undefined, { commitment: "confirmed" });
    const tokenMinter = pda("token_minter");
    const localToken = pda("local_token", mint.toBuffer());
    const custody = pda("custody", mint.toBuffer());
    await program.methods
      .addLocalToken({})
      .accountsPartial({
        tokenController: payer.publicKey,
        tokenMinter,
        localToken,
        custodyTokenAccount: custody,
        localTokenMint: mint,
        program: program.programId,
      })
      .rpc({ commitment: "confirmed" });
    const tokenPair = pda("token_pair", Buffer.from("0"), remoteToken.toBuffer());
    await program.methods
      .linkTokenPair({ remoteDomain: 0, remoteToken, localToken })
      .accountsPartial({
        tokenController: payer.publicKey,
        tokenMinter,
        tokenPair,
        program: program.programId,
      })
      .rpc({ commitment: "confirmed" });
    await mintTo(connection, payer, mint, custody, payer, 100000n, [], { commitment: "confirmed" });
    vault = (
      await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true, "confirmed", {
        commitment: "confirmed",
      })
    ).address;
    const messenger = await program.account.tokenMessenger.fetch(pda("token_messenger"), "confirmed");
    feeAta = (
      await getOrCreateAssociatedTokenAccount(connection, payer, mint, messenger.feeRecipient, true, "confirmed", {
        commitment: "confirmed",
      })
    ).address;
    sender = (
      await program.account.remoteTokenMessenger.fetch(pda("remote_token_messenger", Buffer.from("0")), "confirmed")
    ).tokenMessenger;
  });

  for (const threshold of [1000, 1500, 2000, 2500]) {
    it(`delivers threshold ${threshold}, pays fees, and skips a used nonce`, async () => {
      const before = await getAccount(connection, vault, "confirmed");
      const feeBefore = await getAccount(connection, feeAta, "confirmed");
      const message = buildMessage(threshold);
      assert.isString(await deliver(message));
      assert.equal((await getAccount(connection, vault, "confirmed")).amount - before.amount, 990n);
      assert.equal((await getAccount(connection, feeAta, "confirmed")).amount - feeBefore.amount, 10n);
      assert.isNull(await deliver(message));
      assert.equal((await getAccount(connection, vault, "confirmed")).amount - before.amount, 990n);
    });
  }

  it("requires explicit selection of an inventory token account", async () => {
    const inventory = (
      await getOrCreateAssociatedTokenAccount(connection, payer, mint, payer.publicKey, false, "confirmed", {
        commitment: "confirmed",
      })
    ).address;
    const message = buildMessage(1000, inventory);
    await rejects(deliver(message), /Token recipient does not match/);
    assert.isString(await deliver(message, inventory));
    assert.equal((await getAccount(connection, inventory, "confirmed")).amount, 990n);
  });

  it("leaves a nonce unused after on-chain rejection and permits retry", async () => {
    const message = buildMessage(1000, vault, true);
    await rejects(deliver(message));
    const usedNonce = PublicKey.findProgramAddressSync(
      [Buffer.from("used_nonce"), message.subarray(12, 44)],
      transmitter.programId
    )[0];
    assert.isNull(await transmitter.account.usedNonce.fetchNullable(usedNonce, "confirmed"));
    sender.toBuffer().copy(message, 44);
    assert.isString(await deliver(message));
  });
});
