import * as anchor from "@anchor-lang/core";
import { AnchorError, AnchorProvider, Wallet } from "@anchor-lang/core";
import { Keypair, PublicKey, ComputeBudgetProgram } from "@solana/web3.js";
import { assert } from "chai";
import {
  createMint,
  getOrCreateAssociatedTokenAccount,
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  getAssociatedTokenAddressSync,
  getAccount,
} from "@solana/spl-token";
import { common } from "./SvmSpoke.common";

const { provider, program, connection, assertSE, owner } = common;

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

  it("Maximum number of new accounts", async () => {
    // Each call to create ATA invokes 4 additional inner CPIs, so above 12 we would hit Max instruction trace length
    // limit of 64.
    const numberOfAccounts = 12;
    const authorities = Array.from({ length: numberOfAccounts }, () => Keypair.generate().publicKey);
    const associatedTokens = authorities.map((authority) => getAssociatedTokenAddressSync(mint, authority));

    const remainingAccounts = authorities.flatMap((authority, index) => [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: associatedTokens[index], isWritable: true, isSigner: false },
    ]);

    // Test the instruction-trace limit, allowing headroom for random ATA addresses' variable PDA-search cost.
    const computeBudgetInstruction = ComputeBudgetProgram.setComputeUnitLimit({ units: 500_000 });
    const createTokenAccountsInstruction = await program.methods
      .createTokenAccounts()
      .accounts({ mint, tokenProgram: TOKEN_PROGRAM_ID })
      .remainingAccounts(remainingAccounts)
      .instruction();
    const transaction = new anchor.web3.Transaction();
    transaction.add(computeBudgetInstruction);
    transaction.add(createTokenAccountsInstruction);
    await anchor.web3.sendAndConfirmTransaction(connection, transaction, [payer], { commitment: "confirmed" });

    // Verify all accounts were created
    for (const associatedToken of associatedTokens) {
      const associatedTokenAccount = await getAccount(connection, associatedToken);
      assert.isTrue(associatedTokenAccount.isInitialized, "Account not initialized");
    }
  });
});
