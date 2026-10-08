import * as anchor from "@anchor-lang/core";
import { BN, Program } from "@anchor-lang/core";
import { Keypair, PublicKey, SystemProgram, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { assert } from "chai";
import { randomBytes } from "crypto";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { common } from "./SvmSpoke.common";
import { getSpokePoolProgram } from "../../src/svm/web3-v1";
import { closeExpiredFillStatuses } from "../../scripts/svm/closeRelayerPdas";

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
    } catch (error: any) {
      const text = [error.toString(), ...(error.logs ?? [])].join("\n");
      if (!text.includes(name)) throw new Error(text);
      return;
    }
    assert.fail(`Expected ${name}`);
  };

  it("creates fill statuses with a PDA payer and permissionlessly reclaims their rent", async () => {
    const { state } = await common.initializeState();
    const submitter = Keypair.generate();
    const payer = fillPayer(submitter.publicKey);
    const relayHash = randomBytes(32);
    const status = fillStatus(relayHash);
    const prefundedRelayHash = randomBytes(32);
    const prefundedStatus = fillStatus(prefundedRelayHash);
    const fillDeadline = Number(await common.getCurrentTime(program, state)) + 10;
    const fillStatusRent = await connection.getMinimumBalanceForRentExemption(45);
    const prefundedLamports = await connection.getMinimumBalanceForRentExemption(0);
    const initialFloat = fillStatusRent * 2;
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
      .testCreateV5FillStatus([...relayHash], fillDeadline)
      .accountsPartial({
        submitter: submitter.publicKey,
        payer,
        fillStatus: status,
        systemProgram: SystemProgram.programId,
      })
      .signers([submitter])
      .rpc();
    const account = await program.account.fillStatusAccount.fetch(status);
    assert.hasAnyKeys(account.status, ["filled"]);
    assert.equal(account.rentRecipient.toBase58(), payer.toBase58());
    assert.equal(account.fillDeadline, fillDeadline);

    await expectError(
      program.methods
        .testCreateV5FillStatus([...relayHash], fillDeadline)
        .accountsPartial({
          submitter: submitter.publicKey,
          payer,
          fillStatus: status,
          systemProgram: SystemProgram.programId,
        })
        .signers([submitter])
        .rpc(),
      "RelayFilled"
    );

    await sendAndConfirmTransaction(
      connection,
      new Transaction().add(
        SystemProgram.transfer({
          fromPubkey: providerPayer.publicKey,
          toPubkey: prefundedStatus,
          lamports: prefundedLamports,
        })
      ),
      [providerPayer]
    );
    await program.methods
      .testCreateV5FillStatus([...prefundedRelayHash], fillDeadline)
      .accountsPartial({
        submitter: submitter.publicKey,
        payer,
        fillStatus: prefundedStatus,
        systemProgram: SystemProgram.programId,
      })
      .signers([submitter])
      .rpc();
    assert.equal(await connection.getBalance(payer), prefundedLamports);

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
      program.methods
        .closeFillPda()
        .accountsPartial({ state, rentRecipient: wrongRecipient, fillStatus: status })
        .rpc(),
      "NotRelayer"
    );

    await program.methods.closeFillPda().accountsPartial({ state, rentRecipient: payer, fillStatus: status }).rpc();
    await program.methods
      .closeFillPda()
      .accountsPartial({ state, rentRecipient: payer, fillStatus: prefundedStatus })
      .rpc();
    assert.isNull(await connection.getAccountInfo(status));
    assert.isNull(await connection.getAccountInfo(prefundedStatus));
    assert.equal(await connection.getBalance(payer), initialFloat + prefundedLamports);
  });

  it("discovers cleanup accounts by submitter without events and closes only expired matching statuses", async () => {
    const { state } = await common.initializeState();
    const currentTime = Number(await common.getCurrentTime(program, state));
    const cleanupProgram = getSpokePoolProgram(provider, { programId: program.programId.toBase58() });
    const submitter = Keypair.generate();
    const otherSubmitter = Keypair.generate();
    const rent = await connection.getMinimumBalanceForRentExemption(45);
    const statuses: PublicKey[] = [];
    for (const [owner, deadlines] of [
      [submitter, [currentTime - 1, currentTime, currentTime + 1]],
      [otherSubmitter, [currentTime - 1]],
    ] as const) {
      const payer = fillPayer(owner.publicKey);
      await sendAndConfirmTransaction(
        connection,
        new Transaction().add(
          SystemProgram.transfer({
            fromPubkey: providerPayer.publicKey,
            toPubkey: payer,
            lamports: rent * deadlines.length,
          })
        ),
        [providerPayer],
        { commitment: "confirmed", preflightCommitment: "confirmed" }
      );
      for (const deadline of deadlines) {
        const relayHash = randomBytes(32);
        const status = fillStatus(relayHash);
        statuses.push(status);
        // This test-only entrypoint creates status accounts without emitting FilledRelay events.
        await program.methods
          .testCreateV5FillStatus([...relayHash], deadline)
          .accountsPartial({ submitter: owner.publicKey, payer, fillStatus: status })
          .signers([owner])
          .rpc({ commitment: "confirmed", preflightCommitment: "confirmed" });
      }
    }
    const target = { submitter: submitter.publicKey };
    assert.equal(await closeExpiredFillStatuses(cleanupProgram, state, target, currentTime), 1);
    assert.isNull(await connection.getAccountInfo(statuses[0]));
    for (const status of statuses.slice(1)) assert.isNotNull(await connection.getAccountInfo(status));
    assert.equal(await connection.getBalance(fillPayer(submitter.publicKey)), rent);
    assert.equal(await closeExpiredFillStatuses(cleanupProgram, state, target, currentTime), 0);

    await common.setCurrentTime(program, state, Keypair.generate(), new BN(currentTime + 2));
    assert.equal(await closeExpiredFillStatuses(cleanupProgram, state, target, currentTime + 2), 2);
    assert.equal(await connection.getBalance(fillPayer(submitter.publicKey)), rent * 3);
    assert.isNotNull(await connection.getAccountInfo(statuses[3]));
  });

  it("rejects noncanonical payer and fill-status accounts", async () => {
    const submitter = Keypair.generate();
    const relayHash = randomBytes(32);
    const payer = fillPayer(submitter.publicKey);
    const status = fillStatus(relayHash);

    await expectError(
      program.methods
        .testCreateV5FillStatus([...relayHash], 1)
        .accountsPartial({
          submitter: submitter.publicKey,
          payer: Keypair.generate().publicKey,
          fillStatus: status,
          systemProgram: SystemProgram.programId,
        })
        .signers([submitter])
        .rpc(),
      "InvalidFillPayer"
    );
    await expectError(
      program.methods
        .testCreateV5FillStatus([...relayHash], 1)
        .accountsPartial({
          submitter: submitter.publicKey,
          payer,
          fillStatus: Keypair.generate().publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([submitter])
        .rpc(),
      "InvalidFillStatusAccount"
    );
  });

  it("binds partial and full withdrawals to the submitter", async () => {
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
        .accountsPartial({ submitter: stranger.publicKey, payer, systemProgram: SystemProgram.programId })
        .signers([stranger])
        .rpc(),
      "ConstraintSeeds"
    );

    await expectError(
      program.methods
        .withdrawV5FillPayer(new BN(rentMinimum + 1))
        .accountsPartial({ submitter: submitter.publicKey, payer, systemProgram: SystemProgram.programId })
        .signers([submitter])
        .rpc(),
      "insufficient funds for rent"
    );
    assert.equal(await connection.getBalance(payer), initialFloat);

    await program.methods
      .withdrawV5FillPayer(new BN(rentMinimum))
      .accountsPartial({ submitter: submitter.publicKey, payer, systemProgram: SystemProgram.programId })
      .signers([submitter])
      .rpc();
    assert.equal(await connection.getBalance(payer), rentMinimum);

    await program.methods
      .withdrawV5FillPayer(new BN("18446744073709551615"))
      .accountsPartial({ submitter: submitter.publicKey, payer, systemProgram: SystemProgram.programId })
      .signers([submitter])
      .rpc();
    assert.equal(await connection.getBalance(payer), 0);
  });
});
