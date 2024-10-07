import * as anchor from "@coral-xyz/anchor";
import * as crypto from "crypto";
import { Keypair, PublicKey } from "@solana/web3.js";
import { common } from "./SvmSpoke.common";

const { provider, program, connection, assertSE, assert } = common;

describe("svm_spoke.instruction_params", () => {
  anchor.setProvider(provider);

  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;

  // We use different caller in each test as instructionData seed is derived from initializer's address.
  let caller: Keypair;
  let instructionParams: PublicKey;

  const initializeInstructionParams = async (totalSize: number) => {
    const initializeInstructionParamsAccounts = { signer: caller.publicKey, instructionParams };
    const ix = await program.methods
      .initializeInstructionParams(totalSize)
      .accounts(initializeInstructionParamsAccounts)
      .instruction();
    await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);
  };

  const writeInstructionParams = async (data: Buffer) => {
    // Should not exceed message size limit when writing to the data account
    const maxInstructionParamsFragment = 900;

    for (let i = 0; i < data.length; i += maxInstructionParamsFragment) {
      const fragment = data.slice(i, i + maxInstructionParamsFragment);
      const writeInstructionParamsAccounts = { signer: caller.publicKey, instructionParams };
      const ix = await program.methods
        .writeInstructionParamsFragment(i, fragment)
        .accounts(writeInstructionParamsAccounts)
        .instruction();
      await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);
    }
  };

  beforeEach(async () => {
    caller = Keypair.generate();

    await connection.requestAirdrop(caller.publicKey, 10_000_000_000); // 10 SOL
    await new Promise((resolve) => setTimeout(resolve, 500)); // Wait so that subsequent transactions have funds.

    [instructionParams] = PublicKey.findProgramAddressSync(
      [Buffer.from("instruction_params"), caller.publicKey.toBuffer()],
      program.programId
    );
  });

  it("Initializes instruction params", async () => {
    const totalSize = 100;

    await initializeInstructionParams(totalSize);

    const instructionParamsAccount = await connection.getAccountInfo(instructionParams);
    if (instructionParamsAccount === null) throw new Error("Account not found");
    assertSE(instructionParamsAccount.data.length, totalSize, "Instruction params size mismatch");
  });

  it("Writes short instruction params", async () => {
    const totalSize = 100;
    const inputData = crypto.randomBytes(totalSize);

    await initializeInstructionParams(totalSize);

    await writeInstructionParams(inputData);

    const instructionParamsAccount = await connection.getAccountInfo(instructionParams);
    if (instructionParamsAccount === null) throw new Error("Account not found");
    assertSE(instructionParamsAccount.data, inputData, "Instruction params mismatch");
  });

  it("Writes long instruction params", async () => {
    const totalSize = 10000;
    const inputData = crypto.randomBytes(totalSize);

    await initializeInstructionParams(totalSize);

    await writeInstructionParams(inputData);

    const instructionParamsAccount = await connection.getAccountInfo(instructionParams);
    if (instructionParamsAccount === null) throw new Error("Account not found");
    assertSE(instructionParamsAccount.data, inputData, "Instruction params mismatch");
  });

  it("Cannot write to another caller's instruction params", async () => {
    const totalSize = 100;
    const inputData = crypto.randomBytes(totalSize);

    // Initializes instruction data from the caller.
    await initializeInstructionParams(totalSize);

    // Try to write to the instruction data from a default payer should fail due to instructionParams seed mismatch.
    try {
      const writeInstructionParamsAccounts = { instructionParams };
      await program.methods.writeInstructionParamsFragment(0, inputData).accounts(writeInstructionParamsAccounts).rpc();
      assert.fail("Write instruction params should have failed");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assertSE(err.error.errorCode.code, "ConstraintSeeds", "Expected error code ConstraintSeeds");
    }
  });

  it("Cannot close another caller's instruction params", async () => {
    const totalSize = 100;

    // Initializes instruction data from the caller.
    await initializeInstructionParams(totalSize);

    // Try to close the instruction data from a default payer should fail due to instructionData seed mismatch.
    try {
      const closeInstructionParamsAccounts = { instructionParams };
      await program.methods.closeInstructionParams().accounts(closeInstructionParamsAccounts).rpc();
      assert.fail("Close instruction params should have failed");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assertSE(err.error.errorCode.code, "ConstraintSeeds", "Expected error code ConstraintSeeds");
    }
  });

  it("Closes instruction params", async () => {
    const totalSize = 100;

    await initializeInstructionParams(totalSize);

    const ix = await program.methods.closeInstructionParams().accounts({ signer: caller.publicKey }).instruction();
    await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);

    // Instruction params account should not exist.
    const instructionParamsAccount = await connection.getAccountInfo(instructionParams);
    assert.isNull(instructionParamsAccount, "Instruction params account not closed");
  });
});
