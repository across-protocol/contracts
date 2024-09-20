import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  getAccount,
} from "@solana/spl-token";
import { PublicKey, Keypair } from "@solana/web3.js";
import { readProgramEvents, calculateRelayHashUint8Array } from "../../src/SvmUtils";
import { common } from "./SvmSpoke.common";
const { provider, connection, program, owner, chainId, seedBalance } = common;
const { recipient, initializeState, setCurrentTime, assertSE, assert } = common;

describe("svm_spoke.fill", () => {
  anchor.setProvider(provider);
  const payer = anchor.AnchorProvider.env().wallet.payer;
  const relayer = Keypair.generate();
  const otherRelayer = Keypair.generate();

  let state: PublicKey, mint: PublicKey, relayerTA: PublicKey, recipientTA: PublicKey, otherRelayerTA: PublicKey;

  const relayAmount = 500000;
  let relayData: any; // reused relay data for all tests.
  let accounts: any; // Store accounts to simplify contract interactions.

  function updateRelayData(newRelayData: any) {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );

    accounts = {
      state,
      signer: relayer.publicKey,
      relayer: relayer.publicKey,
      recipient: recipient,
      mintAccount: mint,
      relayerTA: relayerTA,
      recipientTA: recipientTA,
      fillStatus: fillStatusPDA,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };
  }

  before("Creates token mint and associated token accounts", async () => {
    mint = await createMint(connection, payer, owner, owner, 6);
    recipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;
    relayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;
    otherRelayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, otherRelayer.publicKey)).address;

    await mintTo(connection, payer, mint, relayerTA, owner, seedBalance);
    await mintTo(connection, payer, mint, otherRelayerTA, owner, seedBalance);

    await connection.requestAirdrop(relayer.publicKey, 10_000_000_000); // 10 SOL
    await connection.requestAirdrop(otherRelayer.publicKey, 10_000_000_000); // 10 SOL
  });

  beforeEach(async () => {
    state = await initializeState();

    const initialRelayData = {
      depositor: recipient,
      recipient: recipient,
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: new BN(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: new BN(Math.floor(Math.random() * 1000000)), // force that we always have a new deposit id.
      fillDeadline: new BN(Math.floor(Date.now() / 1000) + 60), // 1 minute from now
      exclusivityDeadline: new BN(Math.floor(Date.now() / 1000) + 30), // 30 seconds from now
      message: Buffer.from("Test message"),
    };

    updateRelayData(initialRelayData);
  });

  it("Fills a V3 relay and verifies balances", async () => {
    // Verify recipient's balance before the fill
    let recipientAccount = await getAccount(connection, recipientTA);
    assertSE(recipientAccount.amount, "0", "Recipient's balance should be 0 before the fill");

    // Verify relayer's balance before the fill
    let relayerAccount = await getAccount(connection, relayerTA);
    assertSE(relayerAccount.amount, seedBalance, "Relayer's balance should be equal to seed balance before the fill");

    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();

    // Verify relayer's balance after the fill
    relayerAccount = await getAccount(connection, relayerTA);
    assertSE(
      relayerAccount.amount,
      seedBalance - relayAmount,
      "Relayer's balance should be reduced by the relay amount"
    );

    // Verify recipient's balance after the fill
    recipientAccount = await getAccount(connection, recipientTA);
    assertSE(recipientAccount.amount, relayAmount, "Recipient's balance should be increased by the relay amount");
  });

  it("Verifies FilledV3Relay event after filling a relay", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();

    // Fetch and verify the FilledV3Relay event
    await new Promise((resolve) => setTimeout(resolve, 500));
    const events = await readProgramEvents(connection, program);
    const event = events.find((event) => event.name === "filledV3Relay").data;
    assert.isNotNull(event, "FilledV3Relay event should be emitted");

    // Verify that the event data matches the relay data.
    Object.keys(relayData).forEach((key) => {
      assertSE(event[key], relayData[key], `${key.charAt(0).toUpperCase() + key.slice(1)} should match`);
    });
  });

  it("Fails to fill a V3 relay after the fill deadline", async () => {
    updateRelayData({ ...relayData, fillDeadline: new BN(Math.floor(Date.now() / 1000) - 69) }); // 69 seconds ago

    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    try {
      await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();
      assert.fail("Fill should have failed due to fill deadline passed");
    } catch (err) {
      assert.include(err.toString(), "FillDeadlinePassed", "Expected FillDeadlinePassed error");
    }
  });

  it("Fails to fill a V3 relay by non-exclusive relayer before exclusivity deadline", async () => {
    accounts.signer = otherRelayer.publicKey;
    accounts.relayer = otherRelayer.publicKey;
    accounts.relayerTA = otherRelayerTA;

    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    try {
      await program.methods
        .fillV3Relay(relayHash, relayData, new BN(1))
        .accounts(accounts)
        .signers([otherRelayer])
        .rpc();
      assert.fail("Fill should have failed due to non-exclusive relayer before exclusivity deadline");
    } catch (err) {
      assert.include(err.toString(), "NotExclusiveRelayer", "Expected NotExclusiveRelayer error");
    }
  });

  it("Allows fill by non-exclusive relayer after exclusivity deadline", async () => {
    updateRelayData({ ...relayData, exclusivityDeadline: new BN(Math.floor(Date.now() / 1000) - 30) });

    accounts.signer = otherRelayer.publicKey;
    accounts.relayer = otherRelayer.publicKey;
    accounts.relayerTA = otherRelayerTA;

    const recipientAccountBefore = await getAccount(connection, recipientTA);
    const relayerAccountBefore = await getAccount(connection, otherRelayerTA);

    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([otherRelayer]).rpc();

    // Verify relayer's balance after the fill
    const relayerAccountAfter = await getAccount(connection, otherRelayerTA);
    assertSE(
      relayerAccountAfter.amount,
      BigInt(relayerAccountBefore.amount) - BigInt(relayAmount),
      "Relayer's balance should be reduced by the relay amount"
    );

    // Verify recipient's balance after the fill
    const recipientAccountAfter = await getAccount(connection, recipientTA);
    assertSE(
      recipientAccountAfter.amount,
      BigInt(recipientAccountBefore.amount) + BigInt(relayAmount),
      "Recipient's balance should be increased by the relay amount"
    );
  });

  it("Fails to fill a V3 relay with the same deposit data multiple times", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);

    // First fill attempt
    await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();

    // Second fill attempt with the same data
    try {
      await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();
      assert.fail("Fill should have failed due to AlreadyFilled error");
    } catch (err) {
      assert.include(err.toString(), "AlreadyFilled", "Expected AlreadyFilled error");
    }
  });

  it("Closes the fill PDA after the fill", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);

    const closeFillPdaAccounts = {
      state,
      signer: relayer.publicKey,
      fillStatus: accounts.fillStatus,
      systemProgram: anchor.web3.SystemProgram.programId,
    };

    // Execute the fill_v3_relay call
    await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();

    // Verify the fill PDA exists before closing
    const fillStatusAccountBefore = await connection.getAccountInfo(accounts.fillStatus);
    assert.isNotNull(fillStatusAccountBefore, "Fill PDA should exist before closing");

    // Attempt to close the fill PDA before the fill deadline should fail.
    try {
      await program.methods.closeFillPda(relayHash, relayData).accounts(closeFillPdaAccounts).signers([relayer]).rpc();
      assert.fail("Closing fill PDA should have failed before fill deadline");
    } catch (err) {
      assert.include(err.toString(), "FillDeadlineNotPassed", "Expected FillDeadlineNotPassed error");
    }

    // Set the current time to past the fill deadline
    await setCurrentTime(program, state, relayer, relayData.fillDeadline.add(new BN(1)));

    // Close the fill PDA
    await program.methods.closeFillPda(relayHash, relayData).accounts(closeFillPdaAccounts).signers([relayer]).rpc();

    // Verify the fill PDA is closed
    const fillStatusAccountAfter = await connection.getAccountInfo(accounts.fillStatus);
    assert.isNull(fillStatusAccountAfter, "Fill PDA should be closed after closing");
  });

  it("Fetches FillStatusAccount before and after fillV3Relay", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId);

    // Fetch FillStatusAccount before fillV3Relay
    let fillStatusAccount = await program.account.fillStatusAccount.fetchNullable(fillStatusPDA);
    assert.isNull(fillStatusAccount, "FillStatusAccount should be uninitialized before fillV3Relay");

    // Fill the relay
    await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();

    // Fetch FillStatusAccount after fillV3Relay
    fillStatusAccount = await program.account.fillStatusAccount.fetch(fillStatusPDA);
    assert.isNotNull(fillStatusAccount, "FillStatusAccount should be initialized after fillV3Relay");
    assert.equal(JSON.stringify(fillStatusAccount.status), `{\"filled\":{}}`, "FillStatus should be Filled");
    assert.equal(fillStatusAccount.relayer.toString(), relayer.publicKey.toString(), "Caller should be set as relayer");
  });

  it("Fails to fill a relay when fills are paused", async () => {
    // Pause fills
    await program.methods.pauseFills(true).accounts({ state, signer: owner }).rpc();
    const stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedFills, "Fills should be paused");

    // Try to fill the relay. This should fail because fills are paused.
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    try {
      await program.methods.fillV3Relay(relayHash, relayData, new BN(1)).accounts(accounts).signers([relayer]).rpc();
      assert.fail("Should not be able to fill relay when fills are paused");
    } catch (err) {
      assert.include(err.toString(), "Fills are currently paused!", "Expected fills paused error");
    }
  });

  it("Fails to fill a relay to wrong recipient", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);

    // Create new accounts as derived from wrong recipient.
    const wrongRecipient = Keypair.generate().publicKey;
    const wrongRecipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, wrongRecipient)).address;
    const [wrongFillStatus] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId);

    try {
      await program.methods
        .fillV3Relay(relayHash, relayData, new BN(1))
        .accounts({
          ...accounts,
          recipient: wrongRecipient,
          recipientTA: wrongRecipientTA,
          fillStatus: wrongFillStatus,
        })
        .signers([relayer])
        .rpc();
      assert.fail("Should not be able to fill relay to wrong recipient");
    } catch (err) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "InvalidFillRecipient", "Expected error code InvalidFillRecipient");
    }
  });
});
