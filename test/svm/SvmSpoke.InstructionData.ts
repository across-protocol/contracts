import * as anchor from "@coral-xyz/anchor";
import * as crypto from "crypto";
import { Keypair, PublicKey } from "@solana/web3.js";
import { common } from "./SvmSpoke.common";
import { LargeInstructionCoder } from "./utils";

const { provider, program, connection, assertSE, assert } = common;

describe("svm_spoke.instruction_data", () => {
  anchor.setProvider(provider);

  // We use different caller in each test as instructionData seed is derived from initializer's address.
  let caller: Keypair;
  let instructionData: PublicKey;

  const initializeInstructionData = async (totalSize: number) => {
    const ix = await program.methods
      .initializeInstructionData(totalSize)
      .accounts({ signer: caller.publicKey })
      .instruction();
    await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);
  };

  const writeInstructionData = async (data: Buffer) => {
    // Anchor encoder buffer limit - 4 bytes vector length - 4 bytes for u32 offset.
    const maxInstructionDataFragment = 1000 - 4 - 4;

    for (let i = 0; i < data.length; i += maxInstructionDataFragment) {
      const fragment = data.slice(i, i + maxInstructionDataFragment);
      const ix = await program.methods
        .writeInstructionDataFragment(i, fragment)
        .accounts({ signer: caller.publicKey })
        .instruction();
      await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);
    }
  };

  beforeEach(async () => {
    caller = Keypair.generate();

    await connection.requestAirdrop(caller.publicKey, 10_000_000_000); // 10 SOL
    await new Promise((resolve) => setTimeout(resolve, 500)); // Wait so that subsequent transactions have funds.

    [instructionData] = PublicKey.findProgramAddressSync(
      [Buffer.from("instruction_data"), caller.publicKey.toBuffer()],
      program.programId
    );
  });

  it("Initializes instruction data", async () => {
    const totalSize = 100;

    await initializeInstructionData(totalSize);

    const instructionDataAccount = await program.account.instructionData.fetch(instructionData);
    assertSE(instructionDataAccount.data.length, totalSize, "Instruction data size mismatch");
  });

  it("Writes short instruction data", async () => {
    const totalSize = 100;
    const inputData = crypto.randomBytes(totalSize);

    await initializeInstructionData(totalSize);

    await writeInstructionData(inputData);

    const instructionDataAccount = await program.account.instructionData.fetch(instructionData);
    assertSE(instructionDataAccount.data, inputData, "Instruction data mismatch");
  });

  it("Writes long instruction data", async () => {
    const totalSize = 10000;
    const inputData = crypto.randomBytes(totalSize);

    await initializeInstructionData(totalSize);

    await writeInstructionData(inputData);

    const instructionDataAccount = await program.account.instructionData.fetch(instructionData);
    assertSE(instructionDataAccount.data, inputData, "Instruction data mismatch");
  });

  it("Cannot write to another caller's instruction data", async () => {
    const totalSize = 100;
    const inputData = crypto.randomBytes(totalSize);

    // Initializes instruction data from the caller.
    await initializeInstructionData(totalSize);

    // Try to write to the instruction data from a default payer should fail due to instructionData seed mismatch.
    try {
      await program.methods.writeInstructionDataFragment(0, inputData).accounts({ instructionData }).rpc();
      assert.fail("Write instruction data should have failed");
    } catch (err) {
      assert.instanceOf(err, anchor.AnchorError);
      assertSE(err.error.errorCode.code, "ConstraintSeeds", "Expected error code ConstraintSeeds");
    }
  });

  it("Calls with large instruction data", async () => {
    const inputSize = 10000;
    const inputData = crypto.randomBytes(inputSize);

    // Wrap the input data in another `write_instruction_data_fragment` instruction to write the whole data in a single call.
    const instructionCoder = new LargeInstructionCoder(program.idl);
    const ixDataBytes = instructionCoder.encode("writeInstructionDataFragment", {
      offset: 0,
      fragment: inputData,
    });

    await initializeInstructionData(ixDataBytes.length);

    await writeInstructionData(ixDataBytes);

    // Check if the data account holds the correct instruction data.
    let instructionDataAccount = await program.account.instructionData.fetch(instructionData);
    assertSE(instructionDataAccount.data, ixDataBytes, "Instruction data mismatch");

    // Accounts passed to WriteInstructionDataFragment context.
    const executeAccountMetas = [
      { pubkey: caller.publicKey, isWritable: true, isSigner: true },
      { pubkey: instructionData, isWritable: true, isSigner: false },
    ];

    // Execute the call that should overwrite large data account in a single call.
    const ix = await program.methods
      .callWithInstructionData()
      .accounts({ instructionData })
      .remainingAccounts(executeAccountMetas)
      .instruction();
    await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);

    // This should have overwritten original instruction data account with the random inputData.
    instructionDataAccount = await program.account.instructionData.fetch(instructionData);
    assertSE(instructionDataAccount.data.slice(0, inputSize), inputData, "Data mismatch");
  });

  it("Cannot close another caller's instruction data", async () => {
    const totalSize = 100;

    // Initializes instruction data from the caller.
    await initializeInstructionData(totalSize);

    // Try to close the instruction data from a default payer should fail due to instructionData seed mismatch.
    try {
      await program.methods.closeInstructionData().accounts({ instructionData }).rpc();
      assert.fail("Close instruction data should have failed");
    } catch (err) {
      assert.instanceOf(err, anchor.AnchorError);
      assertSE(err.error.errorCode.code, "ConstraintSeeds", "Expected error code ConstraintSeeds");
    }
  });

  it("Closes instruction data", async () => {
    const totalSize = 100;

    await initializeInstructionData(totalSize);

    const ix = await program.methods.closeInstructionData().accounts({ signer: caller.publicKey }).instruction();
    await anchor.web3.sendAndConfirmTransaction(connection, new anchor.web3.Transaction().add(ix), [caller]);

    // Instruction data account should not exist.
    try {
      await program.account.instructionData.fetch(instructionData);
      assert.fail("Instruction data account should not exist");
    } catch (err) {
      assert.include(err.toString(), "Account does not exist or has no data", "Expected account fetch error");
    }
  });
});
