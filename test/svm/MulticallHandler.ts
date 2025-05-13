import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, Wallet, Program } from "@coral-xyz/anchor";
import { Keypair, PublicKey } from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  createTransferCheckedInstruction,
} from "@solana/spl-token";
import { MulticallHandler } from "../../target/types/multicall_handler";
import { MulticallHandlerCoder } from "../../src/svm/web3-v1";
import { common } from "./SvmSpoke.common";

const { provider, owner, connection, assertSE } = common;

describe("multicall_handler", () => {
  anchor.setProvider(provider);

  const program = anchor.workspace.MulticallHandler as Program<MulticallHandler>;

  let handlerSigner: PublicKey, mint: PublicKey, handlerATA: PublicKey;

  const payer = (AnchorProvider.env().wallet as Wallet).payer;
  const mintDecimals = 6;
  const tokenAmount = 10_000_000_000;

  beforeEach(async () => {
    [handlerSigner] = PublicKey.findProgramAddressSync([Buffer.from("handler_signer")], program.programId);

    mint = await createMint(connection, payer, owner, owner, mintDecimals);

    handlerATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, handlerSigner, true)).address;

    await mintTo(connection, payer, mint, handlerATA, provider.publicKey, tokenAmount);
  });

  it("Sends out tokens from the handler", async () => {
    const recipient = Keypair.generate().publicKey;
    const recipientATA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;

    const transferIx = createTransferCheckedInstruction(
      handlerATA,
      mint,
      recipientATA,
      handlerSigner,
      tokenAmount,
      mintDecimals
    );

    const multicallHandlerCoder = new MulticallHandlerCoder([transferIx]);

    const handlerMessage = multicallHandlerCoder.encode();

    await program.methods
      .handleV3AcrossMessage(handlerMessage)
      .remainingAccounts(multicallHandlerCoder.compiledKeyMetas)
      .rpc();

    const recipientBal = await provider.connection.getTokenAccountBalance(recipientATA);
    assertSE(recipientBal.value.amount, tokenAmount, "Wrong recipient balance");
  });
});
