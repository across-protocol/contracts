import * as anchor from "@coral-xyz/anchor";
import { AnchorError, AnchorProvider, BN, Wallet, web3 } from "@coral-xyz/anchor";
import { Keypair, PublicKey } from "@solana/web3.js";
import { assert } from "chai";
import { common } from "./SvmSpoke.common";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import { createMint, getOrCreateAssociatedTokenAccount, mintTo, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import {
  loadExecuteRelayerRefundLeafParams,
  relayerRefundHashFn,
  RelayerRefundLeafSolana,
  RelayerRefundLeafType,
  readProgramEvents,
} from "./utils";

const { provider, program, owner, initializeState, connection, chainId, assertSE } = common;

describe("svm_spoke.refund_claims", () => {
  anchor.setProvider(provider);

  const claimInitializer = Keypair.generate();

  const relayer = Keypair.generate();

  let state: PublicKey,
    mint: PublicKey,
    tokenAccount: PublicKey,
    claimAccount: PublicKey,
    vault: PublicKey,
    transferLiability: PublicKey;

  const payer = (AnchorProvider.env().wallet as Wallet).payer;
  const initialMintAmount = 10_000_000_000;

  const initializeClaimAccount = async (initializer = claimInitializer) => {
    const initializeClaimAccountIx = await program.methods
      .initializeClaimAccount(mint, tokenAccount)
      .accounts({ signer: initializer.publicKey })
      .instruction();
    await web3.sendAndConfirmTransaction(connection, new web3.Transaction().add(initializeClaimAccountIx), [
      initializer,
    ]);
  };

  const executeRelayerRefundToClaim = async (relayerRefund: BN, initializer = claimInitializer) => {
    // Initialize the claim account if it does not exist.
    try {
      await program.account.claimAccount.fetch(claimAccount);
    } catch (error: any) {
      assert.include(error.toString(), "Account does not exist or has no data", "Expected non-existent account error");
      await initializeClaimAccount(initializer);
    }

    // Prepare leaf using token accounts.
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(0),
      mintPublicKey: mint,
      refundAccounts: [tokenAccount],
      refundAmounts: [relayerRefund],
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    const stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    // Pass claim account as relayer refund address.
    const remainingAccounts = [{ pubkey: claimAccount, isWritable: true, isSigner: false }];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRefundLiability = (await program.account.claimAccount.fetch(claimAccount)).amount.toString();

    // Verify valid leaf
    const executeRelayerRefundLeafAccounts = {
      state,
      rootBundle: rootBundle,
      signer: owner,
      vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint,
      transferLiability,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    const proofAsNumbers = proof.map((p) => Array.from(p));
    await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);
    await program.methods
      .executeRelayerRefundLeaf()
      .accounts(executeRelayerRefundLeafAccounts)
      .remainingAccounts(remainingAccounts)
      .rpc();

    // No funds should have moved out of the vault.
    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    assertSE(iVaultBal, fVaultBal, "Vault balance");

    // Refund liability added in the claim account for the relayer.
    const fRefundLiability = (await program.account.claimAccount.fetch(claimAccount)).amount.toString();
    assertSE(BigInt(fRefundLiability) - BigInt(iRefundLiability), relayerRefund, "Refund liability");
  };

  const claimRelayerRefund = async (initializer = claimInitializer.publicKey) => {
    const claimRelayerRefundAccounts = {
      signer: owner,
      initializer,
      state,
      vault,
      mint,
      tokenAccount,
      claimAccount,
      tokenProgram: TOKEN_PROGRAM_ID,
      program: program.programId,
    };
    await program.methods.claimRelayerRefund().accounts(claimRelayerRefundAccounts).rpc();
  };

  beforeEach(async () => {
    state = await initializeState();
    mint = await createMint(connection, payer, owner, owner, 6);

    tokenAccount = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;
    [claimAccount] = PublicKey.findProgramAddressSync(
      [Buffer.from("claim_account"), mint.toBuffer(), tokenAccount.toBuffer()],
      program.programId
    );

    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true)).address;

    const sig = await connection.requestAirdrop(claimInitializer.publicKey, 10_000_000_000);
    await provider.connection.confirmTransaction(sig);

    // mint mint to vault
    await mintTo(connection, payer, mint, vault, provider.publicKey, initialMintAmount);

    [transferLiability] = PublicKey.findProgramAddressSync(
      [Buffer.from("transfer_liability"), mint.toBuffer()],
      program.programId
    );
  });

  it("Claim Single Relayer Refund", async () => {
    // Execute relayer refund using claim account.
    const relayerRefund = new BN(500000);
    await executeRelayerRefundToClaim(relayerRefund);

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerBal = (await connection.getTokenAccountBalance(tokenAccount)).value.amount;

    // Claim refund for the relayer.
    await claimRelayerRefund();

    // The relayer should have received funds from the vault.
    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerBal = (await connection.getTokenAccountBalance(tokenAccount)).value.amount;
    assertSE(BigInt(iVaultBal) - BigInt(fVaultBal), relayerRefund, "Vault balance");
    assertSE(BigInt(fRelayerBal) - BigInt(iRelayerBal), relayerRefund, "Relayer balance");

    // Verify the ClaimedRelayerRefund event
    await new Promise((resolve) => setTimeout(resolve, 1000)); // Wait for event processing
    const events = await readProgramEvents(connection, program);
    const event = events.find((event) => event.name === "claimedRelayerRefund").data;
    assertSE(event.l2TokenAddress, mint, "l2TokenAddress should match");
    assertSE(event.claimAmount, relayerRefund, "Relayer refund amount should match");
    assertSE(event.refundAddress, tokenAccount, "Relayer refund address should match");
  });

  it("Cannot Double Claim Relayer Refund", async () => {
    // Execute relayer refund using claim account.
    const relayerRefund = new BN(500000);
    await executeRelayerRefundToClaim(relayerRefund);

    // Claim refund for the relayer.
    await claimRelayerRefund();

    // The claim account should have been automatically closed, so repeated claim should fail.
    try {
      await claimRelayerRefund();
      assert.fail("Claiming refund from closed account should fail");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(
        error.error.errorCode.code,
        "AccountNotInitialized",
        "Expected error code AccountNotInitialized"
      );
    }

    // After reinitalizing the claim account, the repeated claim should still fail.
    await initializeClaimAccount();
    try {
      await claimRelayerRefund();
      assert.fail("Claiming refund from reinitalized account should fail");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(error.error.errorCode.code, "ZeroRefundClaim", "Expected error code ZeroRefundClaim");
    }
  });

  it("Claim Multiple Deferred Relayer Refunds", async () => {
    // Execute two relayer refunds to the same claim account.
    const firstRelayerRefund = new BN(500000);
    const secondRelayerRefund = new BN(1000000);
    await executeRelayerRefundToClaim(firstRelayerRefund);
    await executeRelayerRefundToClaim(secondRelayerRefund);

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerBal = (await connection.getTokenAccountBalance(tokenAccount)).value.amount;

    // Claim refund for the relayer.
    await claimRelayerRefund();

    // The relayer should have received both refunds.
    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerBal = (await connection.getTokenAccountBalance(tokenAccount)).value.amount;
    const totalRefund = firstRelayerRefund.add(secondRelayerRefund);
    assertSE(BigInt(iVaultBal) - BigInt(fVaultBal), totalRefund, "Vault balance");
    assertSE(BigInt(fRelayerBal) - BigInt(iRelayerBal), totalRefund, "Relayer balance");
  });

  it("Claim Relayer Refund With Another Initializer", async () => {
    // Fund different claim account initializer.
    const anotherInitializer = Keypair.generate();
    const sig = await connection.requestAirdrop(anotherInitializer.publicKey, 10_000_000_000);
    await provider.connection.confirmTransaction(sig);

    // Execute relayer refund using claim account created by another initializer.
    const relayerRefund = new BN(500000);
    await executeRelayerRefundToClaim(relayerRefund, anotherInitializer);

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerBal = (await connection.getTokenAccountBalance(tokenAccount)).value.amount;

    // Claiming with default initializer should fail.
    try {
      await claimRelayerRefund();
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(
        error.error.errorCode.code,
        "InvalidClaimInitializer",
        "Expected error code InvalidClaimInitializer"
      );
    }

    // Claim refund for the relayer passing the correct initializer account.
    await claimRelayerRefund(anotherInitializer.publicKey);

    // The relayer should have received funds from the vault.
    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerBal = (await connection.getTokenAccountBalance(tokenAccount)).value.amount;
    assertSE(BigInt(iVaultBal) - BigInt(fVaultBal), relayerRefund, "Vault balance");
    assertSE(BigInt(fRelayerBal) - BigInt(iRelayerBal), relayerRefund, "Relayer balance");
  });

  it("Close empty claim account", async () => {
    // Initialize the claim account.
    await initializeClaimAccount(claimInitializer);

    // Should not be able to close the claim account from default wallet as the initializer was different.
    try {
      await program.methods.closeClaimAccount(mint, tokenAccount).accounts({ signer: payer.publicKey }).rpc();
      assert.fail("Closing claim account from different initializer should fail");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(
        error.error.errorCode.code,
        "InvalidClaimInitializer",
        "Expected error code InvalidClaimInitializer"
      );
    }

    // Close the claim account from initializer before executing relayer refunds.
    await program.methods
      .closeClaimAccount(mint, tokenAccount)
      .accounts({ signer: claimInitializer.publicKey })
      .signers([claimInitializer])
      .rpc();

    // Claim account should be closed now.
    try {
      await program.account.claimAccount.fetch(claimAccount);
      assert.fail("Claim account should be closed");
    } catch (error: any) {
      assert.include(error.toString(), "Account does not exist or has no data", "Expected non-existent account error");
    }
  });

  it("Cannot close non-empty claim account", async () => {
    // Execute relayer refund using claim account.
    const relayerRefund = new BN(500000);
    await executeRelayerRefundToClaim(relayerRefund);

    // It should be not possible to close the claim account with non-zero refund liability.
    try {
      await program.methods
        .closeClaimAccount(mint, tokenAccount)
        .accounts({ signer: claimInitializer.publicKey })
        .signers([claimInitializer])
        .rpc();
      assert.fail("Closing claim account with non-zero refund liability should fail");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(error.error.errorCode.code, "NonZeroRefundClaim", "Expected error code NonZeroRefundClaim");
    }
  });
});
