import { getConfirmedTransaction, provider } from "./provider";
import { workspace } from "@anchor-lang/core";
import { PublicKey, Transaction, TransactionInstruction } from "@solana/web3.js";
import { expect } from "chai";

describe("svm_spoke.event_authority", () => {
  const programId = workspace.SvmSpoke.programId as PublicKey;
  const [eventAuthority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], programId);
  // Anchor's event-CPI dispatcher tag, followed by arbitrary event bytes.
  const data = Buffer.from("e445a52e51cb9a1d00010203", "hex");

  for (const [name, authority, isSigner, code] of [
    ["unsigned canonical authority", eventAuthority, false, 2002],
    ["signed noncanonical authority", provider.wallet.publicKey, true, 2006],
  ] as const) {
    it(`rejects forged events from ${name}`, async () => {
      const blockhash = await provider.connection.getLatestBlockhash();
      const transaction = new Transaction({ ...blockhash, feePayer: provider.wallet.publicKey }).add(
        new TransactionInstruction({
          programId,
          keys: [{ pubkey: authority, isSigner, isWritable: false }],
          data,
        })
      );
      const signed = await provider.wallet.signTransaction(transaction);
      const signature = await provider.connection.sendRawTransaction(signed.serialize(), { skipPreflight: true });
      const result = await getConfirmedTransaction(signature);
      expect(result.meta?.err).to.deep.equal({ InstructionError: [0, { Custom: code }] });
    });
  }
});
