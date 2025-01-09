import * as anchor from "@coral-xyz/anchor";
import * as crypto from "crypto";
import { BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  createApproveCheckedInstruction,
} from "@solana/spl-token";
import { PublicKey, Keypair, Transaction, sendAndConfirmTransaction, ComputeBudgetProgram } from "@solana/web3.js";
import { common } from "./SvmSpoke.common";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import { SlowFillLeaf } from "../../src/types/svm";
import {
  calculateRelayHashUint8Array,
  hashNonEmptyMessage,
  intToU8Array32,
  readEventsUntilFound,
  slowFillHashFn,
} from "../../src/svm";
import { testAcrossPlusMessage } from "./utils";

const { provider, connection, program, owner, chainId, seedBalance, initializeState } = common;
const { recipient, setCurrentTime, assertSE, assert } = common;

describe("svm_spoke.slow_fill", () => {
  anchor.setProvider(provider);
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const relayer = Keypair.generate();
  const otherRelayer = Keypair.generate();
  const { encodedMessage, fillRemainingAccounts } = testAcrossPlusMessage();
  const tokenDecimals = 6;

  let state: PublicKey,
    seed: BN,
    mint: PublicKey,
    relayerTA: PublicKey,
    recipientTA: PublicKey,
    otherRelayerTA: PublicKey,
    vault: PublicKey,
    fillStatus: PublicKey;

  const relayAmount = 500_000;
  let relayData: SlowFillLeaf["relayData"]; // reused relay data for all tests.
  let requestAccounts: any; // Store accounts to simplify program interactions.
  let fillAccounts: any;

  const initialMintAmount = 10_000_000_000;

  async function updateRelayData(newRelayData: SlowFillLeaf["relayData"]) {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    [fillStatus] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHashUint8Array], program.programId);

    // recipientTA could be different for each relayData if custom recipient was passed.
    recipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayData.recipient)).address;

    // Accounts for requestingSlowFill.
    requestAccounts = {
      state,
      signer: relayer.publicKey,
      instructionParams: program.programId,
      recipient: relayData.recipient, // This could be different from global recipient.
      fillStatus,
      systemProgram: anchor.web3.SystemProgram.programId,
    };
    fillAccounts = {
      state,
      signer: relayer.publicKey,
      instructionParams: program.programId,
      mint: mint,
      relayerTokenAccount: relayerTA,
      recipientTokenAccount: recipientTA,
      fillStatus,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };
  }

  const relaySlowFillRootBundle = async (
    slowRelayLeafRecipient = recipient,
    slowRelayLeafChainId = chainId,
    message = encodedMessage
  ) => {
    //TODO: verify that the leaf structure created here is equivalent to the one created by the EVM logic. I think
    // I've gotten the concatenation, endianness, etc correct but want to be sure.
    const slowRelayLeafs: SlowFillLeaf[] = [];
    const slowRelayLeaf: SlowFillLeaf = {
      relayData: {
        depositor: slowRelayLeafRecipient,
        recipient: slowRelayLeafRecipient,
        exclusiveRelayer: relayer.publicKey,
        inputToken: mint,
        outputToken: mint,
        inputAmount: new BN(relayAmount),
        outputAmount: new BN(relayAmount),
        originChainId: new BN(1),
        depositId: intToU8Array32(Math.floor(Math.random() * 1000000)), // Unique ID for each test.
        fillDeadline: Math.floor(Date.now() / 1000) + 60, // 1 minute from now
        exclusivityDeadline: Math.floor(Date.now() / 1000) - 30, // Note we set time in past to avoid exclusivity deadline
        message,
      },
      chainId: slowRelayLeafChainId,
      updatedOutputAmount: new BN(relayAmount),
    };
    await updateRelayData(slowRelayLeaf.relayData);

    slowRelayLeafs.push(slowRelayLeaf);

    const merkleTree = new MerkleTree<SlowFillLeaf>(slowRelayLeafs, slowFillHashFn);

    const slowRelayRoot = merkleTree.getRoot();
    const proof = merkleTree.getProof(slowRelayLeafs[0]);
    const leaf = slowRelayLeafs[0];

    let stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;

    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    const relayerRefundRoot = crypto.randomBytes(32);

    // Relay root bundle
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods
      .relayRootBundle(Array.from(relayerRefundRoot), Array.from(slowRelayRoot))
      .accounts(relayRootBundleAccounts)
      .rpc();

    const proofAsNumbers = proof.map((p) => Array.from(p));
    const relayHash = calculateRelayHashUint8Array(slowRelayLeaf.relayData, chainId);

    return { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle };
  };

  before("Creates token mint and associated token accounts", async () => {
    mint = await createMint(connection, payer, owner, owner, tokenDecimals);
    relayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;
    otherRelayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, otherRelayer.publicKey)).address;

    await mintTo(connection, payer, mint, relayerTA, owner, seedBalance);
    await mintTo(connection, payer, mint, otherRelayerTA, owner, seedBalance);

    await connection.requestAirdrop(relayer.publicKey, initialMintAmount); // 10 SOL
    await connection.requestAirdrop(otherRelayer.publicKey, initialMintAmount); // 10 SOL
  });

  beforeEach(async () => {
    ({ state, seed } = await initializeState());
    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true)).address; // Initialize vault

    // mint mint to vault
    await mintTo(connection, payer, mint, vault, provider.publicKey, initialMintAmount);

    const initialVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(
      BigInt(initialVaultBalance),
      BigInt(initialMintAmount),
      "Initial vault balance should be equal to the minted amount"
    );

    const initialRelayData = {
      depositor: recipient,
      recipient: recipient,
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: new BN(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: intToU8Array32(1),
      fillDeadline: Math.floor(Date.now() / 1000) + 60, // 1 minute from now
      exclusivityDeadline: Math.floor(Date.now() / 1000) + 30, // 30 seconds from now
      message: encodedMessage,
    };

    await updateRelayData(initialRelayData);
  });

  it("Requests a V3 slow fill, verify the event & state change", async () => {
    // Attempt to request a slow fill before the exclusivityDeadline
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));

    try {
      await program.methods.requestV3SlowFill(relayHash, relayData).accounts(requestAccounts).signers([relayer]).rpc();
      assert.fail("Request should have failed due to exclusivity deadline not passed");
    } catch (err: any) {
      assert.include(err.toString(), "NoSlowFillsInExclusivityWindow", "Expected NoSlowFillsInExclusivityWindow error");
    }

    // Set the contract time to be after the exclusivityDeadline
    await setCurrentTime(program, state, relayer, new BN(relayData.exclusivityDeadline + 1));

    const tx = await program.methods
      .requestV3SlowFill(relayHash, relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Fetch and verify the RequestedSlowFill event
    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events.find((event) => event.name === "requestedV3SlowFill")?.data;
    assert.isNotNull(event, "RequestedSlowFill event should be emitted");

    // Verify that the event data matches the relay data.
    Object.entries(relayData).forEach(([key, value]) => {
      if (key === "message") {
        assertSE(event.messageHash, hashNonEmptyMessage(value as Buffer), `MessageHash should match`);
      } else assertSE(event[key], value, `${key.charAt(0).toUpperCase() + key.slice(1)} should match`);
    });
  });

  it("Fails to request a V3 slow fill if the relay has already been filled", async () => {
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));

    // Fill the relay first
    const approveIx = await createApproveCheckedInstruction(
      fillAccounts.relayerTokenAccount,
      fillAccounts.mint,
      fillAccounts.state,
      fillAccounts.signer,
      BigInt(relayData.outputAmount.toString()),
      tokenDecimals
    );
    const fillIx = await program.methods
      .fillV3Relay(relayHash, relayData, new BN(1), relayer.publicKey)
      .accounts(fillAccounts)
      .remainingAccounts(fillRemainingAccounts)
      .instruction();
    const fillTx = new Transaction().add(approveIx, fillIx);
    await sendAndConfirmTransaction(connection, fillTx, [relayer]);

    try {
      await program.methods.requestV3SlowFill(relayHash, relayData).accounts(requestAccounts).signers([relayer]).rpc();
      assert.fail("Request should have failed due to being within exclusivity window");
    } catch (err: any) {
      assert.include(err.toString(), "NoSlowFillsInExclusivityWindow", "Expected NoSlowFillsInExclusivityWindow error");
    }

    // Set the contract time to be after the exclusivityDeadline.
    await setCurrentTime(program, state, relayer, new BN(relayData.exclusivityDeadline + 1));

    // Attempt to request a slow fill after the relay has been filled.
    try {
      await program.methods.requestV3SlowFill(relayHash, relayData).accounts(requestAccounts).signers([relayer]).rpc();
      assert.fail("Request should have failed due to relay already being filled");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidSlowFillRequest", "Expected InvalidSlowFillRequest error");
    }
  });

  it("Fetches FillStatusAccount before and after requestV3SlowFill", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId);

    // Fetch FillStatusAccount before requestV3SlowFill
    let fillStatusAccount = await program.account.fillStatusAccount.fetchNullable(fillStatusPDA);
    assert.isNull(fillStatusAccount, "FillStatusAccount should be uninitialized before requestV3SlowFill");

    // Set the contract time to be after the exclusivityDeadline
    await setCurrentTime(program, state, relayer, new BN(relayData.exclusivityDeadline + 1));

    // Request a slow fill
    await program.methods
      .requestV3SlowFill(Array.from(relayHash), relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Fetch FillStatusAccount after requestV3SlowFill
    fillStatusAccount = await program.account.fillStatusAccount.fetch(fillStatusPDA);
    assert.isNotNull(fillStatusAccount, "FillStatusAccount should be initialized after requestV3SlowFill");
    assert.equal(
      JSON.stringify(fillStatusAccount.status),
      `{\"requestedSlowFill\":{}}`,
      "FillStatus should be RequestedSlowFill"
    );
    assert.equal(fillStatusAccount.relayer.toString(), relayer.publicKey.toString(), "Caller should be set as relayer");
  });

  it("Fails to request a V3 slow fill multiple times for the same fill", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);

    // Set the contract time to be after the exclusivityDeadline
    await setCurrentTime(program, state, relayer, new BN(relayData.exclusivityDeadline + 1));

    // Request a slow fill
    await program.methods
      .requestV3SlowFill(Array.from(relayHash), relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Attempt to request a slow fill again for the same relay
    try {
      await program.methods
        .requestV3SlowFill(Array.from(relayHash), relayData)
        .accounts(requestAccounts)
        .signers([relayer])
        .rpc();
      assert.fail("Request should have failed due to relay already being requested for slow fill");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidSlowFillRequest", "Expected InvalidSlowFillRequest error");
    }
  });

  it("Executes V3 slow relay leaf, verify the event & state change", async () => {
    // Relay root bundle with slow fill leaf.
    const { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle } = await relaySlowFillRootBundle();

    const iVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const iRecipientBal = (await connection.getTokenAccountBalance(recipientTA)).value.amount;

    // Attempt to execute V3 slow relay leaf before requesting slow fill. This should fail before requested,
    // even if there is a valid proof.
    const executeSlowRelayLeafAccounts = {
      state: state,
      rootBundle: rootBundle,
      signer: owner,
      instructionParams: program.programId,
      fillStatus: requestAccounts.fillStatus,
      vault: vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint: mint,
      recipientTokenAccount: recipientTA,
      program: program.programId,
    };
    try {
      await program.methods
        .executeV3SlowRelayLeaf(Array.from(relayHash), leaf, rootBundleId, proofAsNumbers)
        .accounts(executeSlowRelayLeafAccounts)
        .remainingAccounts(fillRemainingAccounts)
        .rpc();
      assert.fail("Execution should have failed due to fill status account not being initialized");
    } catch (err: any) {
      assert.include(err.toString(), "AccountNotInitialized", "Expected AccountNotInitialized error");
    }

    // Request V3 slow fill
    await program.methods
      .requestV3SlowFill(Array.from(relayHash), leaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Execute V3 slow relay leaf after requesting slow fill
    const ix = await program.methods
      .executeV3SlowRelayLeaf(Array.from(relayHash), leaf, rootBundleId, proofAsNumbers)
      .accounts(executeSlowRelayLeafAccounts)
      .remainingAccounts(fillRemainingAccounts)
      .instruction();
    const computeBudgetInstruction = ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 });
    const tx = await sendAndConfirmTransaction(connection, new Transaction().add(computeBudgetInstruction, ix), [
      payer,
    ]);

    // Verify the results
    const fVaultBal = (await connection.getTokenAccountBalance(vault)).value.amount;
    const fRecipientBal = (await connection.getTokenAccountBalance(recipientTA)).value.amount;

    assert.strictEqual(
      BigInt(iVaultBal) - BigInt(fVaultBal),
      BigInt(leaf.updatedOutputAmount.toNumber()),
      "Vault balance should be reduced by relay amount"
    );
    assert.strictEqual(
      BigInt(fRecipientBal) - BigInt(iRecipientBal),
      BigInt(leaf.updatedOutputAmount.toNumber()),
      "Recipient balance should be increased by relay amount"
    );

    // Fetch and verify the FilledRelay event
    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events.find((event) => event.name === "filledV3Relay")?.data;
    assert.isNotNull(event, "FilledRelay event should be emitted");

    // Verify that the event data matches the relay data.
    Object.entries(relayData).forEach(([key, value]) => {
      if (key === "message") {
        assertSE(event.messageHash, hashNonEmptyMessage(value as Buffer), `MessageHash should match`);
      } else assertSE(event[key], value, `${key.charAt(0).toUpperCase() + key.slice(1)} should match`);
    });
    // RelayExecutionInfo should match.
    assertSE(event.relayExecutionInfo.updatedRecipient, relayData.recipient, "UpdatedRecipient should match");
    assertSE(
      event.relayExecutionInfo.updatedMessageHash,
      hashNonEmptyMessage(relayData.message),
      "UpdatedMessageHash should match"
    );
    assertSE(event.relayExecutionInfo.updatedOutputAmount, relayData.outputAmount, "UpdatedOutputAmount should match");
    assert.equal(JSON.stringify(event.relayExecutionInfo.fillType), `{"slowFill":{}}`, "FillType should be SlowFill");
    // These props below are not part of relayData.
    assertSE(event.repaymentChainId, new BN(0), "Repayment chain id should be 0");
    assertSE(event.relayer, PublicKey.default, "Repayment address should be 0");
  });

  it("Fails to request a V3 slow fill when fills are paused", async () => {
    // Pause fills
    const pauseFillsAccounts = {
      state: state,
      signer: owner,
      program: program.programId,
    };
    await program.methods.pauseFills(true).accounts(pauseFillsAccounts).rpc();
    const stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedFills, "Fills should be paused");

    // Attempt to request a slow fill. This should fail because fills are paused.
    try {
      const relayHash = calculateRelayHashUint8Array(relayData, chainId);
      await program.methods
        .requestV3SlowFill(Array.from(relayHash), relayData)
        .accounts(requestAccounts)
        .signers([relayer])
        .rpc();
      assert.fail("Request should have failed due to fills being paused");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "FillsArePaused", "Expected error code FillsArePaused");
    }
  });

  it("Fails to execute V3 slow relay leaf to wrong recipient", async () => {
    // Request V3 slow fill.
    const { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle } = await relaySlowFillRootBundle();
    await program.methods
      .requestV3SlowFill(Array.from(relayHash), leaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Try to execute V3 slow relay leaf with wrong recipient token account should fail.
    const wrongRecipient = Keypair.generate().publicKey;
    const wrongRecipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, wrongRecipient)).address;
    try {
      const executeSlowRelayLeafAccounts = {
        state: state,
        rootBundle,
        signer: owner,
        instructionParams: program.programId,
        fillStatus: requestAccounts.fillStatus,
        vault: vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: mint,
        recipientTokenAccount: wrongRecipientTA,
        program: program.programId,
      };
      await program.methods
        .executeV3SlowRelayLeaf(Array.from(relayHash), leaf, rootBundleId, proofAsNumbers)
        .accounts(executeSlowRelayLeafAccounts)
        .remainingAccounts(fillRemainingAccounts)
        .rpc();
      assert.fail("Execution should have failed due to wrong recipient token account");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "ConstraintTokenOwner", "Expected error code ConstraintTokenOwner");
    }
  });

  it("Cannot replay execute V3 slow relay leaf against wrong fill status account", async () => {
    // Request V3 slow fill for the first recipient.
    const firstRecipient = Keypair.generate().publicKey;
    const {
      relayHash: firstRelayHash,
      leaf: firstLeaf,
      rootBundleId: firstRootBundleId,
      proofAsNumbers: firstProofAsNumbers,
      rootBundle: firstRootBundle,
    } = await relaySlowFillRootBundle(firstRecipient);
    await program.methods
      .requestV3SlowFill(Array.from(firstRelayHash), firstLeaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();
    const firstRecipientTA = recipientTA; // Global recipientTA will get updated when passing the second relayData.
    const firstFillStatus = fillStatus; // Global fillStatus will get updated when passing the second relayData.

    // Request V3 slow fill for the second recipient.
    // Note: we could also had generated single slow relay root for both recipients, but having them relayed in separate
    // root bundles makes it easier to reuse existing test code.
    const secondRecipient = Keypair.generate().publicKey;
    const { relayHash: secondRelayHash, leaf: secondLeaf } = await relaySlowFillRootBundle(secondRecipient);
    await program.methods
      .requestV3SlowFill(Array.from(secondRelayHash), secondLeaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();
    const secondFillStatus = fillStatus; // Global fillStatus got updated with the second relayData.

    const iFirstRecipientBal = (await connection.getTokenAccountBalance(firstRecipientTA)).value.amount;
    // Execute V3 slow relay leaf for the first recipient.
    const executeSlowRelayLeafAccounts = {
      state,
      rootBundle: firstRootBundle,
      signer: owner,
      instructionParams: program.programId,
      fillStatus: firstFillStatus,
      vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint,
      recipientTokenAccount: firstRecipientTA,
      program: program.programId,
    };
    await program.methods
      .executeV3SlowRelayLeaf(Array.from(firstRelayHash), firstLeaf, firstRootBundleId, firstProofAsNumbers)
      .accounts(executeSlowRelayLeafAccounts)
      .remainingAccounts(fillRemainingAccounts)
      .rpc();
    const fFirstRecipientBal = (await connection.getTokenAccountBalance(firstRecipientTA)).value.amount;
    assert.strictEqual(
      BigInt(fFirstRecipientBal) - BigInt(iFirstRecipientBal),
      BigInt(firstLeaf.updatedOutputAmount.toString()),
      "First recipient balance should be increased by its relay amount"
    );

    // Try to replay execute V3 slow relay leaf for the first recipient using the fill status account that is derived
    // from the second relay hash. This should fail due to mismatching relay hash.
    try {
      const executeSlowRelayLeafAccounts = {
        state,
        rootBundle: firstRootBundle,
        signer: owner,
        instructionParams: program.programId,
        fillStatus: secondFillStatus,
        vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint,
        recipientTokenAccount: firstRecipientTA,
        program: program.programId,
      };
      await program.methods
        .executeV3SlowRelayLeaf(Array.from(secondRelayHash), firstLeaf, firstRootBundleId, firstProofAsNumbers)
        .accounts(executeSlowRelayLeafAccounts)
        .remainingAccounts(fillRemainingAccounts)
        .rpc();
      assert.fail("Execution should have failed due to wrong fill status account");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "InvalidRelayHash", "Expected error code InvalidRelayHash");
    }
  });

  it("Fails to execute V3 slow relay leaf for mint inconsistent output_token", async () => {
    // Request V3 slow fill.
    const { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle } = await relaySlowFillRootBundle();
    await program.methods
      .requestV3SlowFill(Array.from(relayHash), leaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Create and fund new accounts as derived from wrong mint account.
    const wrongMint = await createMint(connection, payer, owner, owner, tokenDecimals);
    const wrongRecipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, wrongMint, recipient)).address;
    const wrongVault = (await getOrCreateAssociatedTokenAccount(connection, payer, wrongMint, state, true)).address;
    await mintTo(connection, payer, wrongMint, wrongVault, provider.publicKey, initialMintAmount);

    // Try to execute V3 slow relay leaf with inconsistent mint should fail.
    try {
      const executeSlowRelayLeafAccounts = {
        state,
        rootBundle,
        signer: owner,
        instructionParams: program.programId,
        fillStatus: requestAccounts.fillStatus,
        vault: wrongVault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint: wrongMint,
        recipientTokenAccount: wrongRecipientTA,
        program: program.programId,
      };
      await program.methods
        .executeV3SlowRelayLeaf(Array.from(relayHash), leaf, rootBundleId, proofAsNumbers)
        .accounts(executeSlowRelayLeafAccounts)
        .remainingAccounts(fillRemainingAccounts)
        .rpc();
      assert.fail("Execution should have failed for inconsistent mint");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "InvalidMint", "Expected error code InvalidMint");
    }
  });

  it("Cannot execute V3 slow relay leaf targeted at another chain", async () => {
    // Request V3 slow fill for another chain.
    const anotherChainId = new BN(Math.floor(Math.random() * 1000000));
    const { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle } = await relaySlowFillRootBundle(
      undefined,
      anotherChainId
    );
    await program.methods
      .requestV3SlowFill(Array.from(relayHash), leaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Trying to execute V3 slow relay leaf for another chain should fail as the program overrides chain_id that should
    // invalidate the proofs.
    try {
      const executeSlowRelayLeafAccounts = {
        state,
        rootBundle,
        signer: owner,
        instructionParams: program.programId,
        fillStatus: requestAccounts.fillStatus,
        vault,
        tokenProgram: TOKEN_PROGRAM_ID,
        mint,
        recipientTokenAccount: recipientTA,
        program: program.programId,
      };
      await program.methods
        .executeV3SlowRelayLeaf(Array.from(relayHash), leaf, rootBundleId, proofAsNumbers)
        .accounts(executeSlowRelayLeafAccounts)
        .remainingAccounts(fillRemainingAccounts)
        .rpc();
      assert.fail("Execution should have failed for another chain");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "InvalidMerkleProof", "Expected error code InvalidMerkleProof");
    }
  });

  it("Emits zeroed hash for empty message", async () => {
    // Relay root bundle of slow fill leaf with empty message.
    const { relayHash, leaf, rootBundleId, proofAsNumbers, rootBundle } = await relaySlowFillRootBundle(
      undefined,
      undefined,
      Buffer.alloc(0)
    );

    // Request V3 slow fill
    const tx1 = await program.methods
      .requestV3SlowFill(Array.from(relayHash), leaf.relayData)
      .accounts(requestAccounts)
      .signers([relayer])
      .rpc();

    // Execute V3 slow relay leaf after requesting slow fill
    const executeSlowRelayLeafAccounts = {
      state,
      rootBundle,
      signer: owner,
      instructionParams: program.programId,
      fillStatus: requestAccounts.fillStatus,
      vault,
      tokenProgram: TOKEN_PROGRAM_ID,
      mint,
      recipientTokenAccount: recipientTA,
      program: program.programId,
    };
    const tx2 = await program.methods
      .executeV3SlowRelayLeaf(Array.from(relayHash), leaf, rootBundleId, proofAsNumbers)
      .accounts(executeSlowRelayLeafAccounts)
      .remainingAccounts(fillRemainingAccounts)
      .rpc();

    // Fetch and verify message hash in the RequestedSlowFill and FilledRelay events
    const requestEvents = await readEventsUntilFound(connection, tx1, [program]);
    const requestEvent = requestEvents.find((event) => event.name === "requestedV3SlowFill")?.data;
    assert.isNotNull(requestEvent, "RequestedSlowFill event should be emitted");
    assertSE(requestEvent.messageHash, new Uint8Array(32), `MessageHash should be zeroed`);

    const fillEvents = await readEventsUntilFound(connection, tx2, [program]);
    const fillEvent = fillEvents.find((event) => event.name === "filledV3Relay")?.data;
    assert.isNotNull(fillEvent, "FilledRelay event should be emitted");
    assertSE(fillEvent.messageHash, new Uint8Array(32), `MessageHash should be zeroed`);
    assertSE(
      fillEvent.relayExecutionInfo.updatedMessageHash,
      new Uint8Array(32),
      `UpdatedMessageHash should be zeroed`
    );
  });
});
