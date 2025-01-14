import { Keypair, TransactionInstruction, Transaction, sendAndConfirmTransaction, PublicKey } from "@solana/web3.js";
import { Program, BN } from "@coral-xyz/anchor";
import { RelayData, SlowFillLeaf, RelayerRefundLeafSolana } from "../types/svm";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { LargeAccountsCoder } from "./coders";

/**
 * Loads execute relayer refund leaf parameters.
 */
export async function loadExecuteRelayerRefundLeafParams(
  program: Program<SvmSpoke>,
  caller: PublicKey,
  rootBundleId: number,
  relayerRefundLeaf: RelayerRefundLeafSolana,
  proof: number[][]
) {
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  // Close the instruction params account if the caller has used it before.
  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), caller.toBuffer()],
    program.programId
  );
  const accountInfo = await program.provider.connection.getAccountInfo(instructionParams);
  if (accountInfo !== null) await program.methods.closeInstructionParams().rpc();

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("executeRelayerRefundLeafParams", {
    rootBundleId,
    relayerRefundLeaf,
    proof,
  });

  await program.methods.initializeInstructionParams(instructionParamsBytes.length).rpc();

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    await program.methods.writeInstructionParamsFragment(i, fragment).rpc();
  }
  return instructionParams;
}

/**
 * Closes the instruction parameters account.
 */
export async function closeInstructionParams(program: Program<SvmSpoke>, signer: Keypair) {
  const [instructionParams] = PublicKey.findProgramAddressSync(
    [Buffer.from("instruction_params"), signer.publicKey.toBuffer()],
    program.programId
  );
  const accountInfo = await program.provider.connection.getAccountInfo(instructionParams);
  if (accountInfo !== null) {
    const closeIx = await program.methods.closeInstructionParams().accounts({ signer: signer.publicKey }).instruction();
    await sendAndConfirmTransaction(program.provider.connection, new Transaction().add(closeIx), [signer]);
  }
}

/**
 * Creates instructions to load fill relay parameters.
 */
export async function createFillRelayParamsInstructions(
  program: Program<SvmSpoke>,
  signer: PublicKey,
  relayData: RelayData,
  repaymentChainId: BN,
  repaymentAddress: PublicKey
) {
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("fillRelayParams", {
    relayData,
    repaymentChainId,
    repaymentAddress,
  });

  const loadInstructions: TransactionInstruction[] = [];
  loadInstructions.push(
    await program.methods.initializeInstructionParams(instructionParamsBytes.length).accounts({ signer }).instruction()
  );

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    loadInstructions.push(
      await program.methods.writeInstructionParamsFragment(i, fragment).accounts({ signer }).instruction()
    );
  }

  const closeInstruction = await program.methods.closeInstructionParams().accounts({ signer }).instruction();

  return { loadInstructions, closeInstruction };
}

/**
 * Loads fill relay parameters.
 */
export async function loadFillRelayParams(
  program: Program<SvmSpoke>,
  signer: Keypair,
  relayData: RelayData,
  repaymentChainId: BN,
  repaymentAddress: PublicKey
) {
  // Close the instruction params account if the caller has used it before.
  await closeInstructionParams(program, signer);

  // Execute load instructions sequentially.
  const { loadInstructions } = await createFillRelayParamsInstructions(
    program,
    signer.publicKey,
    relayData,
    repaymentChainId,
    repaymentAddress
  );
  for (let i = 0; i < loadInstructions.length; i += 1) {
    await sendAndConfirmTransaction(program.provider.connection, new Transaction().add(loadInstructions[i]), [signer]);
  }
}

/**
 * Loads request slow fill parameters.
 */
export async function loadRequestSlowFillParams(program: Program<SvmSpoke>, signer: Keypair, relayData: RelayData) {
  // Close the instruction params account if the caller has used it before.
  await closeInstructionParams(program, signer);

  // Execute load instructions sequentially.
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("RequestSlowFillParams", { relayData });

  const loadInstructions: TransactionInstruction[] = [];
  loadInstructions.push(
    await program.methods
      .initializeInstructionParams(instructionParamsBytes.length)
      .accounts({ signer: signer.publicKey })
      .instruction()
  );

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    loadInstructions.push(
      await program.methods
        .writeInstructionParamsFragment(i, fragment)
        .accounts({ signer: signer.publicKey })
        .instruction()
    );
  }

  return loadInstructions;
}

/**
 * Loads execute slow relay leaf parameters.
 */
export async function loadExecuteSlowRelayLeafParams(
  program: Program<SvmSpoke>,
  signer: Keypair,
  slowFillLeaf: SlowFillLeaf,
  rootBundleId: number,
  proof: number[][]
) {
  // Close the instruction params account if the caller has used it before.
  await closeInstructionParams(program, signer);

  // Execute load instructions sequentially.
  const maxInstructionParamsFragment = 900; // Should not exceed message size limit when writing to the data account.

  const accountCoder = new LargeAccountsCoder(program.idl);
  const instructionParamsBytes = await accountCoder.encode("executeSlowRelayLeafParams", {
    slowFillLeaf,
    rootBundleId,
    proof,
  });

  const loadInstructions: TransactionInstruction[] = [];
  loadInstructions.push(
    await program.methods
      .initializeInstructionParams(instructionParamsBytes.length)
      .accounts({ signer: signer.publicKey })
      .instruction()
  );

  for (let i = 0; i < instructionParamsBytes.length; i += maxInstructionParamsFragment) {
    const fragment = instructionParamsBytes.slice(i, i + maxInstructionParamsFragment);
    loadInstructions.push(
      await program.methods
        .writeInstructionParamsFragment(i, fragment)
        .accounts({ signer: signer.publicKey })
        .instruction()
    );
  }

  return loadInstructions;
}
