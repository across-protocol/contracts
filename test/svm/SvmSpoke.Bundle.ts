import * as anchor from "@coral-xyz/anchor";
import { AnchorProvider, BN, Wallet, web3 } from "@coral-xyz/anchor";
import {
  createMint,
  getAssociatedTokenAddressSync,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { ComputeBudgetProgram, Keypair, PublicKey, TransactionInstruction } from "@solana/web3.js";
import { assert } from "chai";
import * as crypto from "crypto";
import { ethers } from "ethers";
import {
  loadExecuteRelayerRefundLeafParams,
  readEventsUntilFound,
  relayerRefundHashFn,
  sendTransactionWithLookupTable,
} from "../../src/svm";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../src/types/svm";
import { MerkleTree } from "../../utils";
import { common } from "./SvmSpoke.common";
import { buildRelayerRefundMerkleTree, randomBigInt, readEvents, readProgramEvents } from "./utils";

const { provider, program, owner, initializeState, connection, chainId, assertSE } = common;

describe("svm_spoke.bundle", () => {
  anchor.setProvider(provider);

  const nonOwner = Keypair.generate();

  const relayerA = Keypair.generate();
  const relayerB = Keypair.generate();

  let state: PublicKey,
    seed: BN,
    mint: PublicKey,
    relayerTA: PublicKey,
    relayerTB: PublicKey,
    vault: PublicKey,
    transferLiability: PublicKey;

  const payer = (AnchorProvider.env().wallet as Wallet).payer;
  const initialMintAmount = 10_000_000_000;

  before(async () => {
    // This test differs by having state within before, not before each block so we can have incrementing rootBundleId
    // values to test against on sequential tests.
    ({ state, seed } = await initializeState());

    mint = await createMint(connection, payer, owner, owner, 6);
    relayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayerA.publicKey)).address;
    relayerTB = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayerB.publicKey)).address;

    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true)).address;

    const sig = await connection.requestAirdrop(nonOwner.publicKey, 10_000_000_000);
    await provider.connection.confirmTransaction(sig);

    // mint mint to vault
    await mintTo(connection, payer, mint, vault, provider.publicKey, initialMintAmount);

    const initialVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(
      BigInt(initialVaultBalance),
      BigInt(initialMintAmount),
      "Initial vault balance should be equal to the minted amount"
    );

    [transferLiability] = PublicKey.findProgramAddressSync(
      [Buffer.from("transfer_liability"), mint.toBuffer()],
      program.programId
    );
  });

  it("Relays Root Bundle", async () => {
    const relayerRefundRootBuffer = crypto.randomBytes(32);
    const relayerRefundRootArray = Array.from(relayerRefundRootBuffer);

    const slowRelayRootBuffer = crypto.randomBytes(32);
    const slowRelayRootArray = Array.from(slowRelayRootBuffer);

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);

    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Try to relay root bundle as non-owner
    let relayRootBundleAccounts = {
      state,
      rootBundle,
      signer: nonOwner.publicKey,
      payer: nonOwner.publicKey,
      program: program.programId,
    };
    try {
      await program.methods
        .relayRootBundle(relayerRefundRootArray, slowRelayRootArray)
        .accounts(relayRootBundleAccounts)
        .signers([nonOwner])
        .rpc();
      assert.fail("Non-owner should not be able to relay root bundle");
    } catch (err: any) {
      assert.include(err.toString(), "Only the owner can call this function!", "Expected owner check error");
    }

    // Relay root bundle as owner
    relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods
      .relayRootBundle(relayerRefundRootArray, slowRelayRootArray)
      .accounts(relayRootBundleAccounts)
      .rpc();

    // Fetch the relayer refund root and slow relay root
    let rootBundleAccountData = await program.account.rootBundle.fetch(rootBundle);
    const relayerRefundRootHex = Buffer.from(rootBundleAccountData.relayerRefundRoot).toString("hex");
    const slowRelayRootHex = Buffer.from(rootBundleAccountData.slowRelayRoot).toString("hex");
    assert.isTrue(
      relayerRefundRootHex === relayerRefundRootBuffer.toString("hex"),
      "Relayer refund root should be set"
    );
    assert.isTrue(slowRelayRootHex === slowRelayRootBuffer.toString("hex"), "Slow relay root should be set");

    // Check that the root bundle index has been incremented
    stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.rootBundleId.toString() === "1", "Root bundle index should be 1");

    // Relay a new root bundle
    const relayerRefundRootBuffer2 = crypto.randomBytes(32);
    const relayerRefundRootArray2 = Array.from(relayerRefundRootBuffer2);

    const slowRelayRootBuffer2 = crypto.randomBytes(32);
    const slowRelayRootArray2 = Array.from(slowRelayRootBuffer2);

    const rootBundleIdBuffer2 = Buffer.alloc(4);
    rootBundleIdBuffer2.writeUInt32LE(stateAccountData.rootBundleId);
    const seeds2 = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer2];
    const [rootBundle2] = PublicKey.findProgramAddressSync(seeds2, program.programId);

    relayRootBundleAccounts = {
      state,
      rootBundle: rootBundle2,
      signer: owner,
      payer: owner,
      program: program.programId,
    };
    await program.methods
      .relayRootBundle(relayerRefundRootArray2, slowRelayRootArray2)
      .accounts(relayRootBundleAccounts)
      .rpc();

    stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.rootBundleId.toString() === "2", "Root bundle index should be 2");
  });

  it("Tests Event Emission in Relay Root Bundle", async () => {
    const relayerRefundRootBuffer = crypto.randomBytes(32);
    const relayerRefundRootArray = Array.from(relayerRefundRootBuffer);
    const slowRelayRootBuffer = crypto.randomBytes(32);
    const slowRelayRootArray = Array.from(slowRelayRootBuffer);

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle as owner
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    const tx = await program.methods
      .relayRootBundle(relayerRefundRootArray, slowRelayRootArray)
      .accounts(relayRootBundleAccounts)
      .rpc();

    // Check for the emitted event
    let events = await readEventsUntilFound(connection, tx, [program]);
    const event = events.find((event) => event.name === "relayedRootBundle")?.data;
    assert.isTrue(event.rootBundleId.toString() === rootBundleId.toString(), "Root bundle ID should match");
    assert.isTrue(
      event.relayerRefundRoot.toString() === relayerRefundRootArray.toString(),
      "Relayer refund root should match"
    );
    assert.isTrue(event.slowRelayRoot.toString() === slowRelayRootArray.toString(), "Slow relay root should match");
  });

  it("Simple Leaf Refunds Relayers", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(400000);
    const relayerBRefund = new BN(100000);

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(69420),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [relayerARefund, relayerBRefund],
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();
    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const iRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    // Verify valid leaf
    let executeRelayerRefundLeafAccounts = {
      signer: owner,
      state: state,
      rootBundle: rootBundle,
      vault: vault,
      mint: mint,
      transferLiability,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    const proofAsNumbers = proof.map((p) => Array.from(p));
    const instructionParams = await loadExecuteRelayerRefundLeafParams(
      program,
      owner,
      stateAccountData.rootBundleId,
      leaf,
      proofAsNumbers
    );
    const tx = await program.methods
      .executeRelayerRefundLeaf()
      .accounts(executeRelayerRefundLeafAccounts)
      .remainingAccounts(remainingAccounts)
      .rpc();

    // Verify the instruction params account has been automatically closed.
    const instructionParamsInfo = await program.provider.connection.getAccountInfo(instructionParams);
    assert.isNull(instructionParamsInfo, "Instruction params account should be closed");

    // Verify the ExecutedRelayerRefundRoot event
    let events = await readEventsUntilFound(connection, tx, [program]);
    let event = events.find((event) => event.name === "executedRelayerRefundRoot")?.data;
    // Remove the expectedValues object and use direct assertions
    assertSE(event.amountToReturn, relayerRefundLeaves[0].amountToReturn, "amountToReturn should match");
    assertSE(event.chainId, chainId, "chainId should match");
    assertSE(event.refundAmounts[0], relayerARefund, "Relayer A refund amount should match");
    assertSE(event.refundAmounts[1], relayerBRefund, "Relayer B refund amount should match");
    assertSE(event.rootBundleId, stateAccountData.rootBundleId, "rootBundleId should match");
    assertSE(event.leafId, leaf.leafId, "leafId should match");
    assertSE(event.l2TokenAddress, mint, "l2TokenAddress should match");
    assertSE(event.refundAddresses[0], relayerA.publicKey, "Relayer A address should match");
    assertSE(event.refundAddresses[1], relayerB.publicKey, "Relayer B address should match");
    assert.isFalse(event.deferredRefunds, "deferredRefunds should be false");
    assertSE(event.caller, owner, "caller should match");

    event = events.find((event) => event.name === "tokensBridged")?.data;
    assertSE(event.amountToReturn, relayerRefundLeaves[0].amountToReturn, "amountToReturn should match");
    assertSE(event.chainId, chainId, "chainId should match");
    assertSE(event.leafId, leaf.leafId, "leafId should match");
    assertSE(event.l2TokenAddress, mint, "l2TokenAddress should match");
    assertSE(event.caller, owner, "caller should match");

    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const fRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    const totalRefund = relayerARefund.add(relayerBRefund).toString();

    assert.strictEqual(BigInt(iVaultBal) - BigInt(fVaultBal), BigInt(totalRefund), "Vault balance");
    assert.strictEqual(BigInt(fRelayerABal) - BigInt(iRelayerABal), BigInt(relayerARefund.toString()), "Relayer A bal");
    assert.strictEqual(BigInt(fRelayerBBal) - BigInt(iRelayerBBal), BigInt(relayerBRefund.toString()), "Relayer B bal");

    // Try to execute the same leaf again. This should fail due to the claimed bitmap.
    try {
      executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Leaf should not be executed multiple times");
    } catch (err: any) {
      assert.include(err.toString(), "Leaf already claimed!", "Expected claimed leaf error");
    }
  });

  it("Test Merkle Proof Verification", async () => {
    const solanaDistributions = 50;
    const evmDistributions = 50;
    const solanaLeafNumber = 13;
    const { relayerRefundLeaves, merkleTree } = buildRelayerRefundMerkleTree({
      totalEvmDistributions: evmDistributions,
      totalSolanaDistributions: solanaDistributions,
      mixLeaves: false,
      chainId: chainId.toNumber(),
      mint,
      svmRelayers: [relayerA.publicKey, relayerB.publicKey],
      svmRefundAmounts: [new BN(randomBigInt(2).toString()), new BN(randomBigInt(2).toString())],
    });

    const invalidRelayerRefundLeaf = {
      isSolana: true,
      leafId: new BN(solanaDistributions + 1),
      chainId: chainId,
      amountToReturn: new BN(0),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [new BN(randomBigInt(2).toString()), new BN(randomBigInt(2).toString())],
    } as RelayerRefundLeafSolana;

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[solanaLeafNumber]);
    const leaf = relayerRefundLeaves[solanaLeafNumber] as RelayerRefundLeafSolana;
    const proofAsNumbers = proof.map((p) => Array.from(p));

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const iRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    // Verify valid leaf with invalid accounts
    let executeRelayerRefundLeafAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    try {
      const wrongRemainingAccounts = [
        { pubkey: Keypair.generate().publicKey, isWritable: true, isSigner: false },
        { pubkey: Keypair.generate().publicKey, isWritable: true, isSigner: false },
      ];

      // Verify valid leaf
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(wrongRemainingAccounts)
        .rpc();
      assert.fail("Should not execute to invalid refund address");
    } catch (err: any) {
      assert.include(err.toString(), "Invalid refund address");
    }

    // Verify valid leaf
    executeRelayerRefundLeafAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

    await program.methods
      .executeRelayerRefundLeaf()
      .accounts(executeRelayerRefundLeafAccounts)
      .remainingAccounts(remainingAccounts)
      .rpc();

    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const fRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    const totalRefund = leaf.refundAmounts[0].add(leaf.refundAmounts[1]).toString();

    assert.strictEqual(BigInt(iVaultBal) - BigInt(fVaultBal), BigInt(totalRefund), "Vault balance");
    assert.strictEqual(
      BigInt(fRelayerABal) - BigInt(iRelayerABal),
      BigInt(leaf.refundAmounts[0].toString()),
      "Relayer A bal"
    );
    assert.strictEqual(
      BigInt(fRelayerBBal) - BigInt(iRelayerBBal),
      BigInt(leaf.refundAmounts[1].toString()),
      "Relayer B bal"
    );

    // Verify invalid leaf
    try {
      const executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(
        program,
        owner,
        stateAccountData.rootBundleId,
        invalidRelayerRefundLeaf as RelayerRefundLeafSolana,
        proofAsNumbers
      );
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Invalid leaf should not be verified");
    } catch (err: any) {
      assert.include(err.toString(), "Invalid Merkle proof");
    }
  });

  it("Test Merkle Proof Verification with Mixed Solana and EVM Leaves", async () => {
    const evmDistributions = 5;
    const solanaDistributions = 5;
    const { relayerRefundLeaves, merkleTree } = buildRelayerRefundMerkleTree({
      totalEvmDistributions: evmDistributions,
      totalSolanaDistributions: solanaDistributions,
      mixLeaves: true,
      chainId: chainId.toNumber(),
      mint,
      svmRelayers: [relayerA.publicKey, relayerB.publicKey],
      svmRefundAmounts: [new BN(randomBigInt(2).toString()), new BN(randomBigInt(2).toString())],
    });

    const root = merkleTree.getRoot();
    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const iRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    // Execute each Solana leaf
    for (let i = 0; i < relayerRefundLeaves.length; i += 1) {
      // Only Solana leaves
      if (!relayerRefundLeaves[i].isSolana) continue;

      const leaf = relayerRefundLeaves[i] as RelayerRefundLeafSolana;
      const proof = merkleTree.getProof(leaf);
      const proofAsNumbers = proof.map((p) => Array.from(p));

      let executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    }

    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const fRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    const totalRefund = relayerRefundLeaves
      .filter((leaf) => leaf.isSolana)
      .reduce((acc, leaf) => acc.add((leaf.refundAmounts[0] as BN).add(leaf.refundAmounts[1] as BN)), new BN(0))
      .toString();

    assert.strictEqual(BigInt(iVaultBal) - BigInt(fVaultBal), BigInt(totalRefund), "Vault balance");
    assert.strictEqual(
      BigInt(fRelayerABal) - BigInt(iRelayerABal),
      BigInt(
        relayerRefundLeaves
          .filter((leaf) => leaf.isSolana)
          .reduce((acc, leaf) => acc.add(leaf.refundAmounts[0] as BN), new BN(0))
          .toString()
      ),
      "Relayer A bal"
    );
    assert.strictEqual(
      BigInt(fRelayerBBal) - BigInt(iRelayerBBal),
      BigInt(
        relayerRefundLeaves
          .filter((leaf) => leaf.isSolana)
          .reduce((acc, leaf) => acc.add(leaf.refundAmounts[1] as BN), new BN(0))
          .toString()
      ),
      "Relayer B bal"
    );
  });

  it("Test Merkle Proof Verification with Sorted Solana and EVM Leaves", async () => {
    const evmDistributions = 5;
    const solanaDistributions = 5;
    const { relayerRefundLeaves, merkleTree } = buildRelayerRefundMerkleTree({
      totalEvmDistributions: evmDistributions,
      totalSolanaDistributions: solanaDistributions,
      mixLeaves: false,
      chainId: chainId.toNumber(),
      mint,
      svmRelayers: [relayerA.publicKey, relayerB.publicKey],
      svmRefundAmounts: [new BN(randomBigInt(2).toString()), new BN(randomBigInt(2).toString())],
    });

    const root = merkleTree.getRoot();
    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const iRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    // Execute each Solana leaf
    for (let i = 0; i < relayerRefundLeaves.length; i += 1) {
      // Only Solana leaves
      if (!relayerRefundLeaves[i].isSolana) continue;

      const leaf = relayerRefundLeaves[i] as RelayerRefundLeafSolana;
      const proof = merkleTree.getProof(leaf);
      const proofAsNumbers = proof.map((p) => Array.from(p));

      let executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    }

    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;
    const fRelayerBBal = (await connection.getTokenAccountBalance(relayerTB)).value.amount;

    const totalRefund = relayerRefundLeaves
      .filter((leaf) => leaf.isSolana)
      .reduce((acc, leaf) => acc.add((leaf.refundAmounts[0] as BN).add(leaf.refundAmounts[1] as BN)), new BN(0))
      .toString();

    assert.strictEqual(BigInt(iVaultBal) - BigInt(fVaultBal), BigInt(totalRefund), "Vault balance");
    assert.strictEqual(
      BigInt(fRelayerABal) - BigInt(iRelayerABal),
      BigInt(
        relayerRefundLeaves
          .filter((leaf) => leaf.isSolana)
          .reduce((acc, leaf) => acc.add(leaf.refundAmounts[0] as BN), new BN(0))
          .toString()
      ),
      "Relayer A bal"
    );
    assert.strictEqual(
      BigInt(fRelayerBBal) - BigInt(iRelayerBBal),
      BigInt(
        relayerRefundLeaves
          .filter((leaf) => leaf.isSolana)
          .reduce((acc, leaf) => acc.add(leaf.refundAmounts[1] as BN), new BN(0))
          .toString()
      ),
      "Relayer B bal"
    );
  });

  it("Execute Leaf Refunds Relayers with invalid chain id", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(400000);
    const relayerBRefund = new BN(100000);

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      // Set chainId to 1000. this is a diffrent chainId than what is set in the initialization. This mimics trying to execute a leaf for another chain on the SVM chain.
      chainId: new BN(1000),
      amountToReturn: new BN(0),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [relayerARefund, relayerBRefund],
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];
    const proofAsNumbers = proof.map((p) => Array.from(p));

    try {
      const executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    } catch (err: any) {
      assert.include(err.toString(), "Invalid chain id");
    }
  });

  it("Execute Leaf Refunds Relayers with invalid mintPublicKey", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(400000);
    const relayerBRefund = new BN(100000);

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(0),
      mintPublicKey: Keypair.generate().publicKey,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [relayerARefund, relayerBRefund],
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    const proofAsNumbers = proof.map((p) => Array.from(p));
    try {
      const executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    } catch (err: any) {
      assert.include(err.toString(), "Invalid mint");
    }
  });

  it("Sequential Leaf Refunds Relayers", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerRefundAmount = new BN(100000);

    // Generate 5 sequential leaves
    for (let i = 0; i < 5; i++) {
      relayerRefundLeaves.push({
        isSolana: true,
        leafId: new BN(i),
        chainId: chainId,
        amountToReturn: new BN(0),
        mintPublicKey: mint,
        refundAddresses: [relayerA.publicKey],
        refundAmounts: [relayerRefundAmount],
      });
    }

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
    const root = merkleTree.getRoot();
    const proof = relayerRefundLeaves.map((leaf) => merkleTree.getProof(leaf).map((p) => Array.from(p)));

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [{ pubkey: relayerTA, isWritable: true, isSigner: false }];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;

    // Execute all leaves
    for (let i = 0; i < 5; i++) {
      const executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(
        program,
        owner,
        stateAccountData.rootBundleId,
        relayerRefundLeaves[i] as RelayerRefundLeafSolana,
        proof[i]
      );
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    }

    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;

    const totalRefund = relayerRefundAmount.mul(new BN(5)).toString();

    assert.strictEqual(BigInt(iVaultBal) - BigInt(fVaultBal), BigInt(totalRefund), "Vault balance");
    assert.strictEqual(BigInt(fRelayerABal) - BigInt(iRelayerABal), BigInt(totalRefund), "Relayer A bal");

    // Try to execute the same leaves again. This should fail due to the claimed bitmap.
    for (let i = 0; i < 5; i++) {
      try {
        const executeRelayerRefundLeafAccounts = {
          state: state,
          rootBundle: rootBundle,
          signer: owner,
          vault: vault,
          tokenProgram: TOKEN_PROGRAM_ID,
          mint: mint,
          transferLiability,
          systemProgram: web3.SystemProgram.programId,
          program: program.programId,
        };
        await loadExecuteRelayerRefundLeafParams(
          program,
          owner,
          stateAccountData.rootBundleId,
          relayerRefundLeaves[i] as RelayerRefundLeafSolana,
          proof[i]
        );
        await program.methods
          .executeRelayerRefundLeaf()
          .accounts(executeRelayerRefundLeafAccounts)
          .remainingAccounts(remainingAccounts)
          .rpc();
        assert.fail("Leaf should not be executed multiple times");
      } catch (err: any) {
        assert.include(err.toString(), "Leaf already claimed!", "Expected claimed leaf error");
      }
    }
  });

  it("Should allow the owner to delete the root bundle", async () => {
    const relayerRefundRootBuffer = crypto.randomBytes(32);
    const slowRelayRootBuffer = crypto.randomBytes(32);
    const relayerRefundRootArray = Array.from(relayerRefundRootBuffer);
    const slowRelayRootArray = Array.from(slowRelayRootBuffer);

    let stateAccountData = await program.account.state.fetch(state);
    const initialRootBundleId = stateAccountData.rootBundleId;
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods
      .relayRootBundle(relayerRefundRootArray, slowRelayRootArray)
      .accounts(relayRootBundleAccounts)
      .rpc();

    // Ensure the root bundle exists before deletion
    let rootBundleData = await program.account.rootBundle.fetch(rootBundle);
    assert.isNotNull(rootBundleData, "Root bundle should exist before deletion");

    // Attempt to delete the root bundle as a non-owner
    try {
      const emergencyDeleteRootBundleAccounts = {
        state,
        rootBundle,
        signer: nonOwner.publicKey,
        closer: nonOwner.publicKey,
        program: program.programId,
      };
      await program.methods
        .emergencyDeleteRootBundle(rootBundleId)
        .accounts(emergencyDeleteRootBundleAccounts)
        .signers([nonOwner])
        .rpc();
      assert.fail("Non-owner should not be able to delete the root bundle");
    } catch (err: any) {
      assert.include(err.toString(), "NotOwner", "Expected error for non-owner trying to delete root bundle");
    }

    // Execute the emergency delete
    const emergencyDeleteRootBundleAccounts = {
      state,
      rootBundle,
      signer: owner,
      closer: owner,
      program: program.programId,
    };
    await program.methods.emergencyDeleteRootBundle(rootBundleId).accounts(emergencyDeleteRootBundleAccounts).rpc();

    // Verify that the root bundle has been deleted
    try {
      rootBundleData = await program.account.rootBundle.fetch(rootBundle);
      assert.fail("Root bundle should have been deleted");
    } catch (err: any) {
      assert.include(err.toString(), "Account does not exist", "Expected error when fetching deleted root bundle");
    }

    // Attempt to add a new root bundle after deletion
    const newRelayerRefundRootBuffer = crypto.randomBytes(32);
    const newSlowRelayRootBuffer = crypto.randomBytes(32);
    const newRelayerRefundRootArray = Array.from(newRelayerRefundRootBuffer);
    const newSlowRelayRootArray = Array.from(newSlowRelayRootBuffer);

    // Create a new root bundle
    stateAccountData = await program.account.state.fetch(state);
    const newRootBundleIdBuffer = Buffer.alloc(4);
    newRootBundleIdBuffer.writeUInt32LE(stateAccountData.rootBundleId);
    const newSeeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), newRootBundleIdBuffer];
    const [newRootBundle] = PublicKey.findProgramAddressSync(newSeeds, program.programId);
    assert.isTrue(
      stateAccountData.rootBundleId === initialRootBundleId + 1,
      `Root bundle index should be ${initialRootBundleId + 1}`
    );

    const newRelayRootBundleAccounts = {
      state,
      rootBundle: newRootBundle,
      signer: owner,
      payer: owner,
      program: program.programId,
    };
    await program.methods
      .relayRootBundle(newRelayerRefundRootArray, newSlowRelayRootArray)
      .accounts(newRelayRootBundleAccounts)
      .rpc();

    // Verify that the new root bundle was created successfully
    const newRootBundleData = await program.account.rootBundle.fetch(newRootBundle);
    const newRelayerRefundRootHex = Buffer.from(newRootBundleData.relayerRefundRoot).toString("hex");
    const newSlowRelayRootHex = Buffer.from(newRootBundleData.slowRelayRoot).toString("hex");
    stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(
      stateAccountData.rootBundleId === initialRootBundleId + 2,
      `Root bundle index should be ${initialRootBundleId + 2}`
    );
    assert.isTrue(
      newRelayerRefundRootHex === newRelayerRefundRootBuffer.toString("hex"),
      "New relayer refund root should be set"
    );
    assert.isTrue(newSlowRelayRootHex === newSlowRelayRootBuffer.toString("hex"), "New slow relay root should be set");
  });

  describe("Execute Max Refunds", () => {
    const executeMaxRefunds = async (testConfig: {
      solanaDistributions: number;
      deferredRefunds: boolean;
      atomicAccountCreation: boolean;
    }) => {
      assert.isTrue(
        !(testConfig.deferredRefunds && testConfig.atomicAccountCreation),
        "Incompatible test configuration"
      );
      // Add leaves for other EVM chains to have non-empty proofs array to ensure we don't run out of memory when processing.
      const evmDistributions = 100; // This would fit in 7 proof array elements.

      const refundAccounts: web3.PublicKey[] = []; // These would hold either token accounts or claim accounts.
      const refundAddresses: web3.PublicKey[] = []; // These are relayer authority addresses used in leaf building.
      const refundAmounts: BN[] = [];

      for (let i = 0; i < testConfig.solanaDistributions; i++) {
        // Will create token account later if needed.
        const tokenOwner = Keypair.generate().publicKey;
        const tokenAccount = getAssociatedTokenAddressSync(mint, tokenOwner);
        refundAddresses.push(tokenOwner);

        const [claimAccount] = PublicKey.findProgramAddressSync(
          [Buffer.from("claim_account"), mint.toBuffer(), tokenOwner.toBuffer()],
          program.programId
        );

        if (!testConfig.deferredRefunds && !testConfig.atomicAccountCreation) {
          await getOrCreateAssociatedTokenAccount(connection, payer, mint, tokenOwner);
          refundAccounts.push(tokenAccount);
        } else if (!testConfig.deferredRefunds && testConfig.atomicAccountCreation) {
          refundAccounts.push(tokenAccount);
        } else {
          await program.methods.initializeClaimAccount().accounts({ mint, refundAddress: tokenOwner }).rpc();
          refundAccounts.push(claimAccount);
        }

        refundAmounts.push(new BN(randomBigInt(2).toString()));
      }

      const { relayerRefundLeaves, merkleTree } = buildRelayerRefundMerkleTree({
        totalEvmDistributions: evmDistributions,
        totalSolanaDistributions: testConfig.solanaDistributions,
        mixLeaves: false,
        chainId: chainId.toNumber(),
        mint,
        svmRelayers: refundAddresses,
        svmRefundAmounts: refundAmounts,
      });

      const root = merkleTree.getRoot();
      const proof = merkleTree.getProof(relayerRefundLeaves[0]);
      const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

      const stateAccountData = await program.account.state.fetch(state);
      const rootBundleId = stateAccountData.rootBundleId;

      const rootBundleIdBuffer = Buffer.alloc(4);
      rootBundleIdBuffer.writeUInt32LE(rootBundleId);
      const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
      const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

      // Relay root bundle
      const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
      await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

      // Verify valid leaf
      const proofAsNumbers = proof.map((p) => Array.from(p));

      const [instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), owner.toBuffer()],
        program.programId
      );

      // We will be using Address Lookup Table (ALT), so to test maximum refunds we better add, not only refund accounts,
      // but also all static accounts.
      const staticAccounts = {
        instructionParams,
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        // Appended by Acnhor `event_cpi` macro:
        eventAuthority: PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId)[0],
        program: program.programId,
      };

      const executeRemainingAccounts = refundAccounts.map((account) => ({
        pubkey: account,
        isWritable: true,
        isSigner: false,
      }));

      const createTokenAccountsRemainingAccounts = testConfig.atomicAccountCreation
        ? refundAddresses.flatMap((authority, index) => [
            { pubkey: authority, isWritable: false, isSigner: false },
            { pubkey: refundAccounts[index], isWritable: true, isSigner: false },
          ])
        : [];

      // Build the instruction to execute relayer refund leaf and write its instruction args to the data account.
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

      const executeInstruction = !testConfig.deferredRefunds
        ? await program.methods
            .executeRelayerRefundLeaf()
            .accounts(staticAccounts)
            .remainingAccounts(executeRemainingAccounts)
            .instruction()
        : await program.methods
            .executeRelayerRefundLeafDeferred()
            .accounts(staticAccounts)
            .remainingAccounts(executeRemainingAccounts)
            .instruction();

      // Build the instruction to increase the CU limit as the default 200k is not sufficient.
      const computeBudgetInstruction = ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 });

      // Insert atomic ATA creation if needed.
      const instructions = [computeBudgetInstruction];
      if (testConfig.atomicAccountCreation)
        instructions.push(
          await program.methods
            .createTokenAccounts()
            .accounts({ mint, tokenProgram: TOKEN_PROGRAM_ID })
            .remainingAccounts(createTokenAccountsRemainingAccounts)
            .instruction()
        );

      // Add relay refund leaf execution instruction.
      instructions.push(executeInstruction);

      // Execute using ALT.
      await sendTransactionWithLookupTable(
        connection,
        instructions,
        (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer
      );

      // Verify all refund account balances (either token or claim accounts).
      await new Promise((resolve) => setTimeout(resolve, 1000)); // Make sure account balances have been synced.
      const refundBalances = await Promise.all(
        refundAccounts.map(async (account) => {
          if (!testConfig.deferredRefunds) {
            return (await connection.getTokenAccountBalance(account)).value.amount;
          } else {
            return (await program.account.claimAccount.fetch(account)).amount.toString();
          }
        })
      );
      refundBalances.forEach((balance, i) => {
        assertSE(balance, refundAmounts[i].toString(), `Refund account ${i} balance should match refund amount`);
      });
    };

    it("Execute Max Refunds to Token Accounts", async () => {
      // Higher refund count hits inner instruction size limit when doing `emit_cpi` on public devnet. On localnet this is
      // not an issue, but we hit out of memory panic above 32 refunds. This should not be an issue as currently Across
      // protocol does not expect this to be above 25.
      const solanaDistributions = 28;

      await executeMaxRefunds({ solanaDistributions, deferredRefunds: false, atomicAccountCreation: false });
    });

    it("Execute Max Refunds to Token Accounts with atomic ATA creation", async () => {
      // Higher refund count hits maximum instruction trace length limit.
      const solanaDistributions = 9;

      await executeMaxRefunds({ solanaDistributions, deferredRefunds: false, atomicAccountCreation: true });
    });

    it("Execute Max Refunds to Claim Accounts", async () => {
      const solanaDistributions = 28;

      await executeMaxRefunds({ solanaDistributions, deferredRefunds: true, atomicAccountCreation: false });
    });
  });

  it("Increments pending amount to HubPool", async () => {
    const initialPendingToHubPool = (await program.account.transferLiability.fetch(transferLiability)).pendingToHubPool;

    const incrementPendingToHubPool = async (amountToReturn: BN) => {
      const relayerRefundLeaves: RelayerRefundLeafType[] = [];
      relayerRefundLeaves.push({
        isSolana: true,
        leafId: new BN(0),
        chainId: chainId,
        amountToReturn,
        mintPublicKey: mint,
        refundAddresses: [],
        refundAmounts: [],
      });
      const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
      const root = merkleTree.getRoot();
      const proof = merkleTree.getProof(relayerRefundLeaves[0]);
      const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;
      let stateAccountData = await program.account.state.fetch(state);
      const rootBundleId = stateAccountData.rootBundleId;
      const rootBundleIdBuffer = Buffer.alloc(4);
      rootBundleIdBuffer.writeUInt32LE(rootBundleId);
      const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
      const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);
      let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
      await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();
      const proofAsNumbers = proof.map((p) => Array.from(p));
      const executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

      await program.methods.executeRelayerRefundLeaf().accounts(executeRelayerRefundLeafAccounts).rpc();
    };

    const zeroAmountToReturn = new BN(0);
    await incrementPendingToHubPool(zeroAmountToReturn);

    let pendingToHubPool = (await program.account.transferLiability.fetch(transferLiability)).pendingToHubPool;
    assert.isTrue(pendingToHubPool.eq(initialPendingToHubPool), "Pending amount should not have changed");

    const firstAmountToReturn = new BN(1_000_000);
    await incrementPendingToHubPool(firstAmountToReturn);

    pendingToHubPool = (await program.account.transferLiability.fetch(transferLiability)).pendingToHubPool;
    assert.isTrue(
      pendingToHubPool.eq(initialPendingToHubPool.add(firstAmountToReturn)),
      "Pending amount should be incremented by first amount"
    );

    const secondAmountToReturn = new BN(2_000_000);
    await incrementPendingToHubPool(secondAmountToReturn);

    pendingToHubPool = (await program.account.transferLiability.fetch(transferLiability)).pendingToHubPool;
    assert.isTrue(
      pendingToHubPool.eq(initialPendingToHubPool.add(firstAmountToReturn.add(secondAmountToReturn))),
      "Pending amount should be incremented by second amount"
    );
  });

  it("Reversed Relayer Leaf Refunds", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerRefundAmount = new BN(100000);

    // Generate 10 sequential leaves. This exceeds 1 claimed bitmap byte so we can test claiming lower index after
    // higher index does not shrink root_bundle account size.
    const numberOfRefunds = 10;
    for (let i = 0; i < numberOfRefunds; i++) {
      relayerRefundLeaves.push({
        isSolana: true,
        leafId: new BN(i),
        chainId: chainId,
        amountToReturn: new BN(0),
        mintPublicKey: mint,
        refundAddresses: [relayerA.publicKey],
        refundAmounts: [relayerRefundAmount],
      });
    }

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
    const root = merkleTree.getRoot();
    const proof = relayerRefundLeaves.map((leaf) => merkleTree.getProof(leaf).map((p) => Array.from(p)));

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [{ pubkey: relayerTA, isWritable: true, isSigner: false }];

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;

    // Execute all leaves in reverse order
    for (let i = numberOfRefunds - 1; i >= 0; i--) {
      const executeRelayerRefundLeafAccounts = {
        state: state,
        rootBundle: rootBundle,
        signer: owner,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        transferLiability,
        systemProgram: web3.SystemProgram.programId,
        program: program.programId,
      };
      await loadExecuteRelayerRefundLeafParams(
        program,
        owner,
        stateAccountData.rootBundleId,
        relayerRefundLeaves[i] as RelayerRefundLeafSolana,
        proof[i]
      );
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    }

    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRelayerABal = (await connection.getTokenAccountBalance(relayerTA)).value.amount;

    const totalRefund = relayerRefundAmount.mul(new BN(numberOfRefunds)).toString();

    assert.strictEqual(BigInt(iVaultBal) - BigInt(fVaultBal), BigInt(totalRefund), "Vault balance");
    assert.strictEqual(BigInt(fRelayerABal) - BigInt(iRelayerABal), BigInt(totalRefund), "Relayer A bal");
  });

  it("Invalid Merkle Leaf should fail", async () => {
    // Create invalid leaf with missing refund amount for the second relayer.
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(400000);

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(0),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [relayerARefund],
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    const stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    // Verify valid leaf
    const executeRelayerRefundLeafAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    const proofAsNumbers = proof.map((p) => Array.from(p));
    await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

    // Mismatched refund amount and account length should fail.
    try {
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assertSE(err.error.errorCode.code, "InvalidMerkleLeaf", "Expected error code InvalidMerkleLeaf");
    }
  });

  describe("Deferred refunds in ExecutedRelayerRefundRoot events", () => {
    const executeRelayerRefundLeaf = async (testConfig: { deferredRefunds: boolean }) => {
      // Create new relayer accounts for each sub-test.
      const relayerA = Keypair.generate();
      const relayerB = Keypair.generate();
      const relayerARefund = new BN(400000);
      const relayerBRefund = new BN(100000);

      let refundA: PublicKey, refundB: PublicKey;

      // Create refund accounts depending on the refund type.
      if (!testConfig.deferredRefunds) {
        refundA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayerA.publicKey)).address;
        refundB = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayerB.publicKey)).address;
      } else {
        [refundA] = PublicKey.findProgramAddressSync(
          [Buffer.from("claim_account"), mint.toBuffer(), relayerA.publicKey.toBuffer()],
          program.programId
        );
        [refundB] = PublicKey.findProgramAddressSync(
          [Buffer.from("claim_account"), mint.toBuffer(), relayerB.publicKey.toBuffer()],
          program.programId
        );
        await program.methods.initializeClaimAccount().accounts({ mint, refundAddress: relayerA.publicKey }).rpc();
        await program.methods.initializeClaimAccount().accounts({ mint, refundAddress: relayerB.publicKey }).rpc();
      }

      // Prepare leaf using token accounts.
      const relayerRefundLeaves: RelayerRefundLeafType[] = [];
      relayerRefundLeaves.push({
        isSolana: true,
        leafId: new BN(0),
        chainId: chainId,
        amountToReturn: new BN(0),
        mintPublicKey: mint,
        refundAddresses: [relayerA.publicKey, relayerB.publicKey],
        refundAmounts: [relayerARefund, relayerBRefund],
      });

      const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

      const root = merkleTree.getRoot();
      const proof = merkleTree.getProof(relayerRefundLeaves[0]);
      const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

      const stateAccountData = await program.account.state.fetch(state);
      const rootBundleId = stateAccountData.rootBundleId;

      const rootBundleIdBuffer = Buffer.alloc(4);
      rootBundleIdBuffer.writeUInt32LE(rootBundleId);
      const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
      const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

      // Relay root bundle
      const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
      await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

      // Pass refund addresses in remaining accounts.
      const remainingAccounts = [
        { pubkey: refundA, isWritable: true, isSigner: false },
        { pubkey: refundB, isWritable: true, isSigner: false },
      ];

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

      if (!testConfig.deferredRefunds) {
        return await program.methods
          .executeRelayerRefundLeaf()
          .accounts(executeRelayerRefundLeafAccounts)
          .remainingAccounts(remainingAccounts)
          .rpc();
      } else {
        return await program.methods
          .executeRelayerRefundLeafDeferred()
          .accounts(executeRelayerRefundLeafAccounts)
          .remainingAccounts(remainingAccounts)
          .rpc();
      }
    };

    it("No deferred refunds in all Token Accounts", async () => {
      const tx = await executeRelayerRefundLeaf({ deferredRefunds: false });

      const events = await readEventsUntilFound(connection, tx, [program]);
      const event = events.find((event) => event.name === "executedRelayerRefundRoot")?.data;
      assert.isFalse(event.deferredRefunds, "deferredRefunds should be false");
    });

    it("Deferred refunds in all Claim Accounts", async () => {
      const tx = await executeRelayerRefundLeaf({ deferredRefunds: true });
      const events = await readEventsUntilFound(connection, tx, [program]);
      const event = events.find((event) => event.name === "executedRelayerRefundRoot")?.data;
      assert.isTrue(event.deferredRefunds, "deferredRefunds should be true");
    });
  });

  it("Cannot execute relayer refund leaf with insufficient pool balance", async () => {
    const vaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;

    // Create a leaf with relayer refund amount larger than as vault balance.
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(vaultBal).add(new BN(1));

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(0),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey],
      refundAmounts: [relayerARefund],
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    const stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [{ pubkey: relayerTA, isWritable: true, isSigner: false }];

    const executeRelayerRefundLeafAccounts = {
      state,
      rootBundle,
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

    // Leaf execution should fail due to insufficient balance.
    try {
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Leaf execution should fail due to insufficient pool balance");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(
        err.error.errorCode.code,
        "InsufficientSpokePoolBalanceToExecuteLeaf",
        "Expected error code InsufficientSpokePoolBalanceToExecuteLeaf"
      );
    }
  });
  it("Fails Leaf Verification Without Leading 64 Bytes", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(400000);
    const relayerBRefund = new BN(100000);

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(69420),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [relayerARefund, relayerBRefund],
    });

    // Custom hash function without leading 64 bytes
    const customRelayerRefundHashFn = (input: RelayerRefundLeafType): string => {
      input = input as RelayerRefundLeafSolana;
      const refundAmountsBuffer = Buffer.concat(
        input.refundAmounts.map((amount) => {
          const buf = Buffer.alloc(8);
          amount.toArrayLike(Buffer, "le", 8).copy(buf);
          return buf;
        })
      );

      const refundAddressesBuffer = Buffer.concat(input.refundAddresses.map((address) => address.toBuffer()));

      // construct a leaf missing the leading blank 64 bytes.
      const contentToHash = Buffer.concat([
        input.amountToReturn.toArrayLike(Buffer, "le", 8),
        input.chainId.toArrayLike(Buffer, "le", 8),
        refundAmountsBuffer,
        input.leafId.toArrayLike(Buffer, "le", 4),
        input.mintPublicKey.toBuffer(),
        refundAddressesBuffer,
      ]);

      return ethers.utils.keccak256(contentToHash);
    };

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, customRelayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    // Attempt to verify the leaf, expecting failure
    let executeRelayerRefundLeafAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    const proofAsNumbers = proof.map((p) => Array.from(p));
    await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

    try {
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Leaf verification should fail without leading 64 bytes");
    } catch (err: any) {
      assert.include(err.toString(), "Invalid Merkle proof", "Expected merkle verification to fail");
    }
  });
  it("Fails Leaf Verification with wrong number of Leading 0 bytes", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const relayerARefund = new BN(400000);
    const relayerBRefund = new BN(100000);

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(69420),
      mintPublicKey: mint,
      refundAddresses: [relayerA.publicKey, relayerB.publicKey],
      refundAmounts: [relayerARefund, relayerBRefund],
    });

    // Custom hash function without leading 64 bytes
    const customRelayerRefundHashFn = (input: RelayerRefundLeafType): string => {
      input = input as RelayerRefundLeafSolana;
      const refundAmountsBuffer = Buffer.concat(
        input.refundAmounts.map((amount) => {
          const buf = Buffer.alloc(8);
          amount.toArrayLike(Buffer, "le", 8).copy(buf);
          return buf;
        })
      );

      const refundAddressesBuffer = Buffer.concat(input.refundAddresses.map((address) => address.toBuffer()));

      // construct a leaf missing the leading blank 64 bytes.
      const contentToHash = Buffer.concat([
        Buffer.alloc(5, 0),
        input.amountToReturn.toArrayLike(Buffer, "le", 8),
        input.chainId.toArrayLike(Buffer, "le", 8),
        refundAmountsBuffer,
        input.leafId.toArrayLike(Buffer, "le", 4),
        input.mintPublicKey.toBuffer(),
        refundAddressesBuffer,
      ]);

      return ethers.utils.keccak256(contentToHash);
    };

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, customRelayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    const remainingAccounts = [
      { pubkey: relayerTA, isWritable: true, isSigner: false },
      { pubkey: relayerTB, isWritable: true, isSigner: false },
    ];

    // Attempt to verify the leaf, expecting failure
    let executeRelayerRefundLeafAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    const proofAsNumbers = proof.map((p) => Array.from(p));
    await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

    try {
      await program.methods
        .executeRelayerRefundLeaf()
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Leaf verification should fail without leading 64 bytes");
    } catch (err: any) {
      assert.include(err.toString(), "Invalid Merkle proof", "Expected merkle verification to fail");
    }
  });

  describe("Execute Max multiple refunds with claims", async () => {
    const executeMaxRefundClaims = async (testConfig: {
      solanaDistributions: number;
      useAddressLookup: boolean;
      separatePhases: boolean;
    }) => {
      // Add leaves for other EVM chains to have non-empty proofs array to ensure we don't run out of memory when processing.
      const evmDistributions = 100; // This would fit in 7 proof array elements.

      const refundAddresses: web3.PublicKey[] = []; // These are relayer authority addresses used in leaf building.
      const claimAccounts: web3.PublicKey[] = [];
      const tokenAccounts: web3.PublicKey[] = [];
      const refundAmounts: BN[] = [];
      const initializeInstructions: TransactionInstruction[] = [];
      const claimInstructions: TransactionInstruction[] = [];

      for (let i = 0; i < testConfig.solanaDistributions; i++) {
        // Create the token account.
        const tokenOwner = Keypair.generate().publicKey;
        const tokenAccount = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, tokenOwner)).address;
        refundAddresses.push(tokenOwner);
        tokenAccounts.push(tokenAccount);

        const [claimAccount] = PublicKey.findProgramAddressSync(
          [Buffer.from("claim_account"), mint.toBuffer(), tokenOwner.toBuffer()],
          program.programId
        );

        // Create instruction to initialize claim account.
        initializeInstructions.push(
          await program.methods.initializeClaimAccount().accounts({ mint, refundAddress: tokenOwner }).instruction()
        );
        claimAccounts.push(claimAccount);

        refundAmounts.push(new BN(randomBigInt(2).toString()));

        // Create instruction to claim refund to the token account.
        const claimRelayerRefundAccounts = {
          signer: owner,
          initializer: owner,
          state,
          vault,
          mint,
          tokenAccount,
          refundAddress: tokenOwner,
          claimAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          program: program.programId,
        };
        claimInstructions.push(
          await program.methods.claimRelayerRefund().accounts(claimRelayerRefundAccounts).instruction()
        );
      }

      const { relayerRefundLeaves, merkleTree } = buildRelayerRefundMerkleTree({
        totalEvmDistributions: evmDistributions,
        totalSolanaDistributions: testConfig.solanaDistributions,
        mixLeaves: false,
        chainId: chainId.toNumber(),
        mint,
        svmRelayers: refundAddresses,
        svmRefundAmounts: refundAmounts,
      });

      const root = merkleTree.getRoot();
      const proof = merkleTree.getProof(relayerRefundLeaves[0]);
      const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

      const stateAccountData = await program.account.state.fetch(state);
      const rootBundleId = stateAccountData.rootBundleId;

      const rootBundleIdBuffer = Buffer.alloc(4);
      rootBundleIdBuffer.writeUInt32LE(rootBundleId);
      const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
      const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

      // Relay root bundle
      const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
      await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

      // Verify valid leaf
      const proofAsNumbers = proof.map((p) => Array.from(p));

      const [instructionParams] = PublicKey.findProgramAddressSync(
        [Buffer.from("instruction_params"), owner.toBuffer()],
        program.programId
      );

      const executeAccounts = {
        instructionParams,
        state,
        rootBundle: rootBundle,
        signer: owner,
        vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint,
        transferLiability,
        program: program.programId,
      };

      const executeRemainingAccounts = claimAccounts.map((account) => ({
        pubkey: account,
        isWritable: true,
        isSigner: false,
      }));

      // Build the instruction to execute relayer refund leaf and write its instruction args to the data account.
      await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);

      const executeInstruction = await program.methods
        .executeRelayerRefundLeafDeferred()
        .accounts(executeAccounts)
        .remainingAccounts(executeRemainingAccounts)
        .instruction();

      // Initialize, execute and claim depending on the chosen method.
      const instructions = [...initializeInstructions, executeInstruction, ...claimInstructions];
      if (!testConfig.separatePhases) {
        // Pack all instructions in one transaction.
        if (testConfig.useAddressLookup)
          await sendTransactionWithLookupTable(
            connection,
            instructions,
            (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer
          );
        else
          await web3.sendAndConfirmTransaction(
            connection,
            new web3.Transaction().add(...instructions),
            [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
            {
              commitment: "confirmed",
            }
          );
      } else {
        // Send claim account initialization, execution and claim in separate transactions.
        if (testConfig.useAddressLookup) {
          await sendTransactionWithLookupTable(
            connection,
            initializeInstructions,
            (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer
          );
          await sendTransactionWithLookupTable(
            connection,
            [executeInstruction],
            (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer
          );
          await sendTransactionWithLookupTable(
            connection,
            claimInstructions,
            (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer
          );
        } else {
          await web3.sendAndConfirmTransaction(
            connection,
            new web3.Transaction().add(...initializeInstructions),
            [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
            {
              commitment: "confirmed",
            }
          );
          await web3.sendAndConfirmTransaction(
            connection,
            new web3.Transaction().add(executeInstruction),
            [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
            {
              commitment: "confirmed",
            }
          );
          await web3.sendAndConfirmTransaction(
            connection,
            new web3.Transaction().add(...claimInstructions),
            [(anchor.AnchorProvider.env().wallet as anchor.Wallet).payer],
            {
              commitment: "confirmed",
            }
          );
        }
      }

      // Verify all refund token account balances.
      const refundBalances = await Promise.all(
        tokenAccounts.map(async (account) => {
          return (await connection.getTokenAccountBalance(account)).value.amount;
        })
      );
      refundBalances.forEach((balance, i) => {
        assertSE(balance, refundAmounts[i].toString(), `Refund account ${i} balance should match refund amount`);
      });
    };

    it("Execute Max multiple refunds with claims in one legacy transaction", async () => {
      // Larger amount would hit transaction message size limit.
      const solanaDistributions = 5;
      await executeMaxRefundClaims({ solanaDistributions, useAddressLookup: false, separatePhases: false });
    });

    it("Execute Max multiple refunds with claims in one versioned transaction", async () => {
      // Larger amount would hit maximum instruction trace length limit.
      const solanaDistributions = 12;
      await executeMaxRefundClaims({ solanaDistributions, useAddressLookup: true, separatePhases: false });
    });

    it("Execute Max multiple refunds with claims in separate phase legacy transactions", async () => {
      // Larger amount would hit transaction message size limit.
      const solanaDistributions = 7;
      await executeMaxRefundClaims({ solanaDistributions, useAddressLookup: false, separatePhases: true });
    });

    it("Execute Max multiple refunds with claims in separate phase versioned transactions", async () => {
      // Larger amount would hit maximum instruction trace length limit.
      const solanaDistributions = 21;
      await executeMaxRefundClaims({ solanaDistributions, useAddressLookup: true, separatePhases: true });
    });
  });
});
