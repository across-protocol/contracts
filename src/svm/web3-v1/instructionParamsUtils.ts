import { Keypair, Transaction, sendAndConfirmTransaction, PublicKey } from "@solana/web3.js";
import { Program } from "@coral-xyz/anchor";
import { RelayerRefundLeafSolana } from "../../types/svm";
import { SvmSpoke } from "../../../target/types/svm_spoke";
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
