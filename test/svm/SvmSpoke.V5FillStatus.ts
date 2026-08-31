import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { Keypair, PublicKey, SystemProgram, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { assert } from "chai";
import { randomBytes } from "crypto";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { common } from "./SvmSpoke.common";

describe("svm_spoke V5 fill-status payer", () => {
  anchor.setProvider(common.provider);
  const { connection, provider } = common;
  const program = common.program as Program<SvmSpoke>;
  const providerPayer = (provider.wallet as anchor.Wallet).payer;

  const fillPayer = (submitter: PublicKey) =>
    PublicKey.findProgramAddressSync([Buffer.from("v5_fill_payer"), submitter.toBuffer()], program.programId)[0];
  const fillStatus = (relayHash: Buffer) =>
    PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId)[0];

  const expectError = async (promise: Promise<unknown>, name: string) => {
    try {
      await promise;
      assert.fail(`Expected ${name}`);
    } catch (error: any) {
      const text = [error.toString(), ...(error.logs ?? [])].join("\n");
      if (!text.includes(name)) throw new Error(text);
    }
  };

  it("creates a fill status without a forwarded signer and permissionlessly reclaims its rent", async () => {
    const { state } = await common.initializeState();
    const submitter = Keypair.generate().publicKey;
    const payer = fillPayer(submitter);
    const relayHash = randomBytes(32);
    const status = fillStatus(relayHash);
    const fillDeadline = Number(await common.getCurrentTime(program, state)) + 10;
    const initialFloat = await connection.getMinimumBalanceForRentExemption(45);
    await sendAndConfirmTransaction(
      connection,
      new Transaction().add(
        SystemProgram.transfer({
          fromPubkey: providerPayer.publicKey,
          toPubkey: payer,
          lamports: initialFloat,
        })
      ),
      [providerPayer]
    );

    await program.methods
      .testCreateV5FillStatus(submitter, [...relayHash], fillDeadline)
      .accounts({ payer, fillStatus: status, systemProgram: SystemProgram.programId })
      .rpc();
    const account = await program.account.fillStatusAccount.fetch(status);
    assert.hasAnyKeys(account.status, ["filled"]);
    assert.equal(account.relayer.toBase58(), payer.toBase58());
    assert.equal(account.fillDeadline, fillDeadline);

    await expectError(
      program.methods
        .testCreateV5FillStatus(submitter, [...relayHash], fillDeadline)
        .accounts({ payer, fillStatus: status, systemProgram: SystemProgram.programId })
        .rpc(),
      "RelayFilled"
    );

    await common.setCurrentTime(program, state, Keypair.generate(), new BN(fillDeadline + 1));

    const wrongRecipient = Keypair.generate().publicKey;
    await sendAndConfirmTransaction(
      connection,
      new Transaction().add(
        SystemProgram.transfer({
          fromPubkey: providerPayer.publicKey,
          toPubkey: wrongRecipient,
          lamports: await connection.getMinimumBalanceForRentExemption(0),
        })
      ),
      [providerPayer]
    );
    await expectError(
      program.methods.closeFillPda().accounts({ state, signer: wrongRecipient, fillStatus: status }).rpc(),
      "NotRelayer"
    );

    await program.methods.closeFillPda().accounts({ state, signer: payer, fillStatus: status }).rpc();
    assert.isNull(await connection.getAccountInfo(status));
    assert.equal(await connection.getBalance(payer), initialFloat);
  });

  it("binds withdrawal to the submitter and preserves a rent-safe remainder", async () => {
    const submitter = Keypair.generate();
    const payer = fillPayer(submitter.publicKey);
    const rentMinimum = await connection.getMinimumBalanceForRentExemption(0);
    const initialFloat = rentMinimum * 2;
    await sendAndConfirmTransaction(
      connection,
      new Transaction().add(
        SystemProgram.transfer({
          fromPubkey: providerPayer.publicKey,
          toPubkey: payer,
          lamports: initialFloat,
        })
      ),
      [providerPayer]
    );

    const stranger = Keypair.generate();
    await expectError(
      program.methods
        .withdrawV5FillPayer(new BN(1))
        .accounts({ submitter: stranger.publicKey, payer, systemProgram: SystemProgram.programId })
        .signers([stranger])
        .rpc(),
      "ConstraintSeeds"
    );

    await expectError(
      program.methods
        .withdrawV5FillPayer(new BN(initialFloat - 1))
        .accounts({ submitter: submitter.publicKey, payer, systemProgram: SystemProgram.programId })
        .signers([submitter])
        .rpc(),
      "FillPayerRemainderNotRentExempt"
    );
    assert.equal(await connection.getBalance(payer), initialFloat);

    await program.methods
      .withdrawV5FillPayer(new BN(rentMinimum))
      .accounts({ submitter: submitter.publicKey, payer, systemProgram: SystemProgram.programId })
      .signers([submitter])
      .rpc();
    assert.equal(await connection.getBalance(payer), rentMinimum);

    await program.methods
      .withdrawV5FillPayer(new BN("18446744073709551615"))
      .accounts({ submitter: submitter.publicKey, payer, systemProgram: SystemProgram.programId })
      .signers([submitter])
      .rpc();
    assert.equal(await connection.getBalance(payer), 0);
  });
});
