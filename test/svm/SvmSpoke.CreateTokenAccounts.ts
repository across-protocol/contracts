import * as anchor from "@coral-xyz/anchor";
import { AnchorError, AnchorProvider, Wallet } from "@coral-xyz/anchor";
import { Keypair, PublicKey } from "@solana/web3.js";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  getAssociatedTokenAddressSync,
  getAccount,
} from "@solana/spl-token";
import { common } from "./SvmSpoke.common";

const { provider, program, connection, assertSE, assert, owner } = common;

describe("svm_spoke.create_token_accounts", () => {
  anchor.setProvider(provider);

  const payer = (AnchorProvider.env().wallet as Wallet).payer;

  let mint: PublicKey;

  beforeEach(async () => {
    mint = await createMint(connection, payer, owner, owner, 6);
  });

  it("Creates single associated token account", async () => {
    const authority = Keypair.generate().publicKey;
    const associatedToken = getAssociatedTokenAddressSync(mint, authority);

    const remainingAccounts = [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedToken, isWritable: true, isSigner: false },
    ];

    await program.methods
      .createTokenAccounts()
      .accounts({ mint, tokenProgram: TOKEN_PROGRAM_ID })
      .remainingAccounts(remainingAccounts)
      .rpc();

    const associatedTokenAccount = await getAccount(connection, associatedToken);
    assertSE(associatedTokenAccount.address, associatedToken, "Wrong address");
    assertSE(associatedTokenAccount.mint, mint, "Wrong mint");
    assertSE(associatedTokenAccount.owner, authority, "Wrong owner");
    assert.isTrue(associatedTokenAccount.isInitialized, "Account not initialized");
  });

  it("Handles already created token account", async () => {
    const authority = Keypair.generate().publicKey;
    const associatedTokenAccount = await getOrCreateAssociatedTokenAccount(connection, payer, mint, authority);
    assertSE(associatedTokenAccount.mint, mint, "Wrong mint");
    assertSE(associatedTokenAccount.owner, authority, "Wrong owner");
    assert.isTrue(associatedTokenAccount.isInitialized, "Account not initialized");

    const remainingAccounts = [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedTokenAccount.address, isWritable: true, isSigner: false },
    ];

    // Should not fail when running against already created account
    await program.methods
      .createTokenAccounts()
      .accounts({ mint, tokenProgram: TOKEN_PROGRAM_ID })
      .remainingAccounts(remainingAccounts)
      .rpc();
  });

  it("Wrong token program", async () => {
    const authority = Keypair.generate().publicKey;
    // By default mint and ATA uses the old token program
    const associatedToken = getAssociatedTokenAddressSync(mint, authority);

    const remainingAccounts = [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedToken, isWritable: true, isSigner: false },
    ];

    // Should fail when passing the new token program
    try {
      await program.methods
        .createTokenAccounts()
        .accounts({ mint, tokenProgram: TOKEN_2022_PROGRAM_ID })
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Should have failed with wrong token program");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assertSE(
        error.error.errorCode.code,
        "ConstraintMintTokenProgram",
        "Expected error code ConstraintMintTokenProgram"
      );
    }
  });

  it("Invalid remaining accounts for ATA creation", async () => {
    const authority = Keypair.generate().publicKey;
    const associatedToken = getAssociatedTokenAddressSync(mint, authority);

    // Omit ATA for the second pair
    const remainingAccounts = [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedToken, isWritable: true, isSigner: false },
      { pubkey: authority, isWritable: false, isSigner: false },
    ];

    // Should fail when passing odd number of remaining accounts
    try {
      await program.methods
        .createTokenAccounts()
        .accounts({ mint, tokenProgram: TOKEN_PROGRAM_ID })
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Should have failed with odd number of remaining accounts");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assertSE(
        error.error.errorCode.code,
        "InvalidATACreationAccounts",
        "Expected error code InvalidATACreationAccounts"
      );
    }
  });

  it("Duplicate accounts", async () => {
    const authority = Keypair.generate().publicKey;
    const associatedToken = getAssociatedTokenAddressSync(mint, authority);

    // Pass duplicate account pairs
    const remainingAccounts = [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedToken, isWritable: true, isSigner: false },
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedToken, isWritable: true, isSigner: false },
    ];

    await program.methods
      .createTokenAccounts()
      .accounts({ mint, tokenProgram: TOKEN_PROGRAM_ID })
      .remainingAccounts(remainingAccounts)
      .rpc();

    const associatedTokenAccount = await getAccount(connection, associatedToken);
    assertSE(associatedTokenAccount.address, associatedToken, "Wrong address");
    assertSE(associatedTokenAccount.mint, mint, "Wrong mint");
    assertSE(associatedTokenAccount.owner, authority, "Wrong owner");
    assert.isTrue(associatedTokenAccount.isInitialized, "Account not initialized");
  });
});
