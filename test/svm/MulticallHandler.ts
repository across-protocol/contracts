import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, Wallet, Program } from "@coral-xyz/anchor";
import { Keypair, PublicKey, AccountMeta } from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  createTransferCheckedInstruction,
} from "@solana/spl-token";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { MulticallHandlerCalls } from "../../src/SvmUtils";
import { common } from "./SvmSpoke.common";

const { provider, owner, connection, assertSE } = common;

describe("multicall_handler", () => {
  anchor.setProvider(provider);

  const program = anchor.workspace.MulticallHandler as Program<MulticallHandler>;

  let pdaSigner: PublicKey, mint: PublicKey, handlerATA: PublicKey;

  const payer = (AnchorProvider.env().wallet as Wallet).payer;
  const mintDecimals = 6;
  const tokenAmount = 10_000_000_000;

  beforeEach(async () => {
    [pdaSigner] = PublicKey.findProgramAddressSync([Buffer.from("pda_signer")], program.programId);

    mint = await createMint(connection, payer, owner, owner, mintDecimals);

    handlerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, pdaSigner, true)).address;

    await mintTo(connection, payer, mint, handlerATA, provider.publicKey, tokenAmount);
  });

  it("handle_v3_across_message", async () => {
    const recipient = Keypair.generate().publicKey;
    const recipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;

    const transferIx = createTransferCheckedInstruction(
      handlerATA,
      mint,
      recipientATA,
      pdaSigner,
      tokenAmount,
      mintDecimals
    );

    const remainingAccounts: AccountMeta[] = [
      ...transferIx.keys.map((key) => ({ pubkey: key.pubkey, isSigner: false, isWritable: key.isWritable })),
      { pubkey: transferIx.programId, isSigner: false, isWritable: false },
    ];

    const accountIndexes = Buffer.from(transferIx.keys.map((_, i) => i));

    const calls = new MulticallHandlerCalls([
      {
        programIndex: accountIndexes.length,
        accountIndexes,
        data: transferIx.data,
      },
    ]);

    const encodedCalls = calls.encode();

    await program.methods.handleV3AcrossMessage(encodedCalls).remainingAccounts(remainingAccounts).rpc();

    const recipientBal = await provider.connection.getTokenAccountBalance(recipientATA);
    assertSE(recipientBal.value.amount, tokenAmount, "Wrong recipient balance");
  });
});
