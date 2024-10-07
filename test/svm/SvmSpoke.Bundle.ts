import * as anchor from "@coral-xyz/anchor";
import * as crypto from "crypto";
import { BN } from "@coral-xyz/anchor";
import {
  AddressLookupTableProgram,
  ComputeBudgetProgram,
  Keypair,
  PublicKey,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import { assert } from "chai";
import { common } from "./SvmSpoke.common";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import { createMint, getOrCreateAssociatedTokenAccount, mintTo, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import {
  relayerRefundHashFn,
  randomAddress,
  randomBigInt,
  RelayerRefundLeaf,
  RelayerRefundLeafSolana,
  RelayerRefundLeafType,
  readProgramEvents,
  convertLeafIdToNumber,
} from "./utils";

const { provider, program, owner, initializeState, connection, chainId, assertSE } = common;

describe("svm_spoke.bundle", () => {
  anchor.setProvider(provider);

  const nonOwner = Keypair.generate();

  const relayerA = Keypair.generate();
  const relayerB = Keypair.generate();

  let state: PublicKey,
    mint: PublicKey,
    relayerTA: PublicKey,
    relayerTB: PublicKey,
    vault: PublicKey,
    transferLiability: PublicKey;

  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const initialMintAmount = 10_000_000_000;

  before(async () => {
    // This test differs by having state within before, not before each block so we can have incrementing rootBundleId
    // values to test against on sequential tests.
    state = await initializeState();
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
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Try to relay root bundle as non-owner
    let relayRootBundleAccounts = { state: state, rootBundle, signer: nonOwner.publicKey };
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
    relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
    const seeds2 = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer2];
    const [rootBundle2] = PublicKey.findProgramAddressSync(seeds2, program.programId);

    relayRootBundleAccounts = { state, rootBundle: rootBundle2, signer: owner };
    await program.methods
      .relayRootBundle(relayerRefundRootArray2, slowRelayRootArray2)
      .accounts(relayRootBundleAccounts)
      .rpc();

    stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.rootBundleId.toString() === "2", "Root bundle index should be 2");
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
      refundAccounts: [relayerTA, relayerTB],
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
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
    const proofAsNumbers = proof.map((p) => Array.from(p));
    await program.methods
      .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
      .accounts(executeRelayerRefundLeafAccounts)
      .remainingAccounts(remainingAccounts)
      .rpc();

    // Verify the ExecutedRelayerRefundRoot event
    await new Promise((resolve) => setTimeout(resolve, 500)); // Wait for event processing
    let events = await readProgramEvents(connection, program);
    let event = events.find((event) => event.name === "executedRelayerRefundRoot").data;

    // Remove the expectedValues object and use direct assertions
    assertSE(event.amountToReturn, relayerRefundLeaves[0].amountToReturn, "amountToReturn should match");
    assertSE(event.chainId, chainId, "chainId should match");
    assertSE(event.refundAmounts[0], relayerARefund, "Relayer A refund amount should match");
    assertSE(event.refundAmounts[1], relayerBRefund, "Relayer B refund amount should match");
    assertSE(event.rootBundleId, stateAccountData.rootBundleId, "rootBundleId should match");
    assertSE(event.leafId, leaf.leafId, "leafId should match");
    assertSE(event.l2TokenAddress, mint, "l2TokenAddress should match");
    assertSE(event.refundAddresses[0], relayerTA, "Relayer A address should match");
    assertSE(event.refundAddresses[1], relayerTB, "Relayer B address should match");
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Leaf should not be executed multiple times");
    } catch (err: any) {
      assert.include(err.toString(), "Leaf already claimed!", "Expected claimed leaf error");
    }
  });

  it("Test Merkle Proof Verification", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    const solanaDistributions = 50;
    const evmDistributions = 50;
    const solanaLeafNumber = 13;

    for (let i = 0; i < solanaDistributions + 1; i++) {
      relayerRefundLeaves.push({
        isSolana: true,
        leafId: new BN(i),
        chainId: chainId,
        amountToReturn: new anchor.BN(randomBigInt(2).toString()),
        mintPublicKey: mint,
        refundAccounts: [relayerTA, relayerTB],
        refundAmounts: [new anchor.BN(randomBigInt(2).toString()), new anchor.BN(randomBigInt(2).toString())],
      });
    }
    const invalidRelayerRefundLeaf = relayerRefundLeaves.pop()!;

    for (let i = 0; i < evmDistributions; i++) {
      relayerRefundLeaves.push({
        isSolana: false,
        leafId: BigInt(i),
        chainId: randomBigInt(2),
        amountToReturn: randomBigInt(),
        l2TokenAddress: randomAddress(),
        refundAddresses: [randomAddress(), randomAddress()],
        refundAmounts: [randomBigInt(), randomBigInt()],
      } as RelayerRefundLeaf);
    }

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[solanaLeafNumber]);
    const leaf = relayerRefundLeaves[13] as RelayerRefundLeafSolana;
    const proofAsNumbers = proof.map((p) => Array.from(p));

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
    try {
      const wrongRemainingAccounts = [
        { pubkey: Keypair.generate().publicKey, isWritable: true, isSigner: false },
        { pubkey: Keypair.generate().publicKey, isWritable: true, isSigner: false },
      ];

      // Verify valid leaf
      await program.methods
        .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(wrongRemainingAccounts)
        .rpc();
    } catch (err: any) {
      assert.include(err.toString(), "Account not found");
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
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
    await program.methods
      .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(
          stateAccountData.rootBundleId,
          convertLeafIdToNumber(invalidRelayerRefundLeaf as RelayerRefundLeafSolana),
          proofAsNumbers
        )
        .accounts(executeRelayerRefundLeafAccounts)
        .remainingAccounts(remainingAccounts)
        .rpc();
      assert.fail("Invalid leaf should not be verified");
    } catch (err: any) {
      assert.include(err.toString(), "Invalid Merkle proof");
    }
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
      refundAccounts: [relayerTA, relayerTB],
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
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
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
      refundAccounts: [relayerTA, relayerTB],
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
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
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
        refundAccounts: [relayerTA],
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
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(
          stateAccountData.rootBundleId,
          convertLeafIdToNumber(relayerRefundLeaves[i] as RelayerRefundLeafSolana),
          proof[i]
        )
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
          systemProgram: anchor.web3.SystemProgram.programId,
          program: program.programId,
        };
        await program.methods
          .executeRelayerRefundLeaf(
            stateAccountData.rootBundleId,
            convertLeafIdToNumber(relayerRefundLeaves[i] as RelayerRefundLeafSolana),
            proof[i]
          )
          .accounts(executeRelayerRefundLeafAccounts)
          .remainingAccounts(remainingAccounts)
          .rpc();
        assert.fail("Leaf should not be executed multiple times");
      } catch (err: any) {
        assert.include(err.toString(), "Leaf already claimed!", "Expected claimed leaf error");
      }
    }
  });

  it("Execute Max Refunds", async () => {
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];

    // Higher refund count hits message size limit due to refund accounts also being present in calldata. This could be
    // resolved by feeding calldata from a buffer account.
    const numberOfRefunds = 21;
    const maxExtendedAccounts = 30; // Maximum number of accounts that can be added to ALT in a single transaction.

    const refundAccounts: anchor.web3.PublicKey[] = [];
    const refundAmounts: BN[] = [];

    for (let i = 0; i < numberOfRefunds; i++) {
      const newRefundAccount = (
        await getOrCreateAssociatedTokenAccount(connection, payer, mint, Keypair.generate().publicKey)
      ).address;
      refundAccounts.push(newRefundAccount);
      refundAmounts.push(new BN(randomBigInt(2).toString()));
    }

    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId: chainId,
      amountToReturn: new BN(0),
      mintPublicKey: mint,
      refundAccounts: refundAccounts,
      refundAmounts: refundAmounts,
    });

    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    let relayRootBundleAccounts = { state, rootBundle, signer: owner };
    await program.methods.relayRootBundle(Array.from(root), Array.from(root)).accounts(relayRootBundleAccounts).rpc();

    // Verify valid leaf
    const proofAsNumbers = proof.map((p) => Array.from(p));

    // We will be using Address Lookup Table (ALT), so to test maximum refunds we better add, not only refund accounts,
    // but also all static accounts.
    const staticAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      transferLiability,
      systemProgram: anchor.web3.SystemProgram.programId,
      // Appended by Acnhor `event_cpi` macro:
      eventAuthority: PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId)[0],
      program: program.programId,
    };

    const remainingAccounts = refundAccounts.map((account) => ({ pubkey: account, isWritable: true, isSigner: false }));

    // Consolidate all accounts (static and remaining) into a single array for the ALT.
    const allAccounts = [...Object.values(staticAccounts), ...refundAccounts];

    // Create instructions for creating and extending the ALT.
    const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
      authority: payer.publicKey,
      payer: payer.publicKey,
      recentSlot: await connection.getSlot(),
    });

    // Submit the ALT creation transaction
    await anchor.web3.sendAndConfirmTransaction(
      connection,
      new anchor.web3.Transaction().add(lookupTableInstruction),
      [payer],
      {
        skipPreflight: true, // Avoids recent slot mismatch in simulation.
      }
    );

    // Extend the ALT with all accounts making sure not to exceed the maximum number of accounts per transaction.
    for (let i = 0; i < allAccounts.length; i += maxExtendedAccounts) {
      const extendInstruction = AddressLookupTableProgram.extendLookupTable({
        lookupTable: lookupTableAddress,
        authority: payer.publicKey,
        payer: payer.publicKey,
        addresses: allAccounts.slice(i, i + maxExtendedAccounts),
      });

      await anchor.web3.sendAndConfirmTransaction(
        connection,
        new anchor.web3.Transaction().add(extendInstruction),
        [payer],
        {
          skipPreflight: true, // Avoids recent slot mismatch in simulation.
        }
      );
    }

    // Avoids invalid ALT index as ALT might not be active yet on the following tx.
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch the AddressLookupTableAccount
    const lookupTableAccount = (await connection.getAddressLookupTable(lookupTableAddress)).value;
    assert(lookupTableAccount !== null, "AddressLookupTableAccount not fetched");

    // Build the instruction to execute relayer refund leaf
    const executeInstruction = await program.methods
      .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
      .accounts(staticAccounts)
      .remainingAccounts(remainingAccounts)
      .instruction();

    // Build the instruction to increase the CU limit as the default 200k is not sufficient.
    const computeBudgetInstruction = ComputeBudgetProgram.setComputeUnitLimit({ units: 500_000 });

    // Create the versioned transaction
    const versionedTx = new VersionedTransaction(
      new TransactionMessage({
        payerKey: payer.publicKey,
        recentBlockhash: (await connection.getLatestBlockhash()).blockhash,
        instructions: [computeBudgetInstruction, executeInstruction],
      }).compileToV0Message([lookupTableAccount])
    );

    // Sign and submit the versioned transaction.
    versionedTx.sign([payer]);
    await connection.sendTransaction(versionedTx);
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
        refundAccounts: [],
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
      const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
      const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);
      let relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(stateAccountData.rootBundleId, convertLeafIdToNumber(leaf), proofAsNumbers)
        .accounts(executeRelayerRefundLeafAccounts)
        .rpc();
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
        refundAccounts: [relayerTA],
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
    const seeds = [Buffer.from("root_bundle"), state.toBuffer(), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner };
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
        systemProgram: anchor.web3.SystemProgram.programId,
        program: program.programId,
      };
      await program.methods
        .executeRelayerRefundLeaf(
          stateAccountData.rootBundleId,
          convertLeafIdToNumber(relayerRefundLeaves[i] as RelayerRefundLeafSolana),
          proof[i]
        )
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
});
