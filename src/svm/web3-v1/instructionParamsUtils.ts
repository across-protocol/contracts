import { Keypair, Transaction, sendAndConfirmTransaction, PublicKey } from "@solana/web3.js";
import { Idl, Program } from "@coral-xyz/anchor";
import { RelayerRefundLeafSolana } from "../../types/svm";
import { SvmSpokeAnchor } from "../assets";
import { LargeAccountsCoder } from "./coders";

// Production and test clients share the methods below, but test IDLs contain extra instructions.
type InstructionParamsProgram = Pick<Program<SvmSpokeAnchor>, "programId" | "provider" | "methods"> & { idl: Idl };

/**
 * Loads execute relayer refund leaf parameters and waits for the writes to be confirmed.
 */
export async function loadExecuteRelayerRefundLeafParams(
  program: InstructionParamsProgram,
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
    // Preflight must see the preceding initialization; wait for confirmed visibility before the caller executes.
    await program.methods
      .writeInstructionParamsFragment(i, fragment)
      .rpc({ preflightCommitment: "processed", commitment: "confirmed" });
  }
  return instructionParams;
}

/**
 * Closes the instruction parameters account.
 */
export async function closeInstructionParams(program: InstructionParamsProgram, signer: Keypair) {
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
