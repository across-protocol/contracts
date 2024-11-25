import * as anchor from "@coral-xyz/anchor";
import { BN, web3 } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  createAccount,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  getAccount,
  getAssociatedTokenAddressSync,
  createApproveCheckedInstruction,
  createReallocateInstruction,
  createEnableCpiGuardInstruction,
  ExtensionType,
} from "@solana/spl-token";
import { PublicKey, Keypair, TransactionInstruction, sendAndConfirmTransaction, Transaction } from "@solana/web3.js";
import { readProgramEvents, calculateRelayHashUint8Array, sendTransactionWithLookupTable } from "../../src/SvmUtils";
import { intToU8Array32 } from "./utils";
import { common, RelayData, FillDataValues } from "./SvmSpoke.common";
import { testAcrossPlusMessage, hashNonEmptyMessage } from "./utils";
const { provider, connection, program, owner, chainId, seedBalance } = common;
const { recipient, initializeState, setCurrentTime, assertSE, assert } = common;

describe("svm_spoke.fill", () => {
  anchor.setProvider(provider);
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const relayer = Keypair.generate();
  const otherRelayer = Keypair.generate();
  const { encodedMessage, fillRemainingAccounts } = testAcrossPlusMessage();
  const tokenDecimals = 6;

  let state: PublicKey,
    mint: PublicKey,
    relayerTA: PublicKey,
    recipientTA: PublicKey,
    otherRelayerTA: PublicKey,
    tokenProgram: PublicKey;

  const relayAmount = 500000;
  let relayData: RelayData; // reused relay data for all tests.

  type FillAccounts = {
    state: PublicKey;
    signer: PublicKey;
    instructionParams: PublicKey;
    mint: PublicKey;
    relayerTokenAccount: PublicKey;
    recipientTokenAccount: PublicKey;
    fillStatus: PublicKey;
    tokenProgram: PublicKey;
    associatedTokenProgram: PublicKey;
    systemProgram: PublicKey;
    program: PublicKey;
  };

  let accounts: FillAccounts; // Store accounts to simplify contract interactions.

  function updateRelayData(newRelayData: RelayData) {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );

    accounts = {
      state,
      signer: relayer.publicKey,
      instructionParams: program.programId,
      mint: mint,
      relayerTokenAccount: relayerTA,
      recipientTokenAccount: recipientTA,
      fillStatus: fillStatusPDA,
      tokenProgram: tokenProgram ?? TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
  }

  const approvedFillV3Relay = async (
    fillDataValues: FillDataValues,
    calledFillAccounts: FillAccounts = accounts,
    callingRelayer: Keypair = relayer
  ) => {
    // Delegate state PDA to pull relayer tokens.
    const approveIx = await createApproveCheckedInstruction(
      calledFillAccounts.relayerTokenAccount,
      calledFillAccounts.mint,
      calledFillAccounts.state,
      calledFillAccounts.signer,
      BigInt(fillDataValues[1].outputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );
    const fillIx = await program.methods
      .fillV3Relay(...fillDataValues)
      .accounts(calledFillAccounts)
      .remainingAccounts(fillRemainingAccounts)
      .instruction();
    const fillTx = new Transaction().add(approveIx, fillIx);
    await sendAndConfirmTransaction(connection, fillTx, [payer, callingRelayer]);
  };

  before("Funds relayer wallets", async () => {
    await connection.requestAirdrop(relayer.publicKey, 10_000_000_000); // 10 SOL
    await connection.requestAirdrop(otherRelayer.publicKey, 10_000_000_000); // 10 SOL
  });

  beforeEach(async () => {
    mint = await createMint(connection, payer, owner, owner, tokenDecimals);
    recipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, recipient)).address;
    relayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, relayer.publicKey)).address;
    otherRelayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, otherRelayer.publicKey)).address;

    await mintTo(connection, payer, mint, relayerTA, owner, seedBalance);
    await mintTo(connection, payer, mint, otherRelayerTA, owner, seedBalance);

    await connection.requestAirdrop(relayer.publicKey, 10_000_000_000); // 10 SOL
    await connection.requestAirdrop(otherRelayer.publicKey, 10_000_000_000); // 10 SOL
  });

  beforeEach(async () => {
    ({ state } = await initializeState());
    tokenProgram = TOKEN_PROGRAM_ID; // Some tests might override this.

    const initialRelayData = {
      depositor: recipient,
      recipient: recipient,
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: new BN(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: intToU8Array32(Math.floor(Math.random() * 1000000)), // force that we always have a new deposit id.
      fillDeadline: Math.floor(Date.now() / 1000) + 60, // 1 minute from now
      exclusivityDeadline: Math.floor(Date.now() / 1000) + 30, // 30 seconds from now
      message: encodedMessage,
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

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);

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
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillV3Relay([relayHash, relayData, new BN(420), otherRelayer.publicKey]);

    // Fetch and verify the FilledV3Relay event
    await new Promise((resolve) => setTimeout(resolve, 500));
    const events = await readProgramEvents(connection, program);
    const event = events.find((event) => event.name === "filledV3Relay").data;
    assert.isNotNull(event, "FilledV3Relay event should be emitted");

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
    assert.equal(JSON.stringify(event.relayExecutionInfo.fillType), `{"fastFill":{}}`, "FillType should be FastFill");
    // These props below are not part of relayData.
    assertSE(event.repaymentChainId, new BN(420), "Repayment chain id should match");
    assertSE(event.relayer, otherRelayer.publicKey, "Repayment address should match");
  });

  it("Fails to fill a V3 relay after the fill deadline", async () => {
    updateRelayData({ ...relayData, fillDeadline: Math.floor(Date.now() / 1000) - 69 }); // 69 seconds ago

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    try {
      await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);
      assert.fail("Fill should have failed due to fill deadline passed");
    } catch (err: any) {
      assert.include(err.toString(), "ExpiredFillDeadline", "Expected ExpiredFillDeadline error");
    }
  });

  it("Fails to fill a V3 relay by non-exclusive relayer before exclusivity deadline", async () => {
    accounts.signer = otherRelayer.publicKey;
    accounts.relayerTokenAccount = otherRelayerTA;

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    try {
      await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey], undefined, otherRelayer);
      assert.fail("Fill should have failed due to non-exclusive relayer before exclusivity deadline");
    } catch (err: any) {
      assert.include(err.toString(), "NotExclusiveRelayer", "Expected NotExclusiveRelayer error");
    }
  });

  it("Allows fill by non-exclusive relayer after exclusivity deadline", async () => {
    updateRelayData({ ...relayData, exclusivityDeadline: Math.floor(Date.now() / 1000) - 100 });

    accounts.signer = otherRelayer.publicKey;
    accounts.relayerTokenAccount = otherRelayerTA;

    const recipientAccountBefore = await getAccount(connection, recipientTA);
    const relayerAccountBefore = await getAccount(connection, otherRelayerTA);

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey], undefined, otherRelayer);

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
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));

    // First fill attempt
    await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);

    // Second fill attempt with the same data
    try {
      await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);
      assert.fail("Fill should have failed due to RelayFilled error");
    } catch (err: any) {
      assert.include(err.toString(), "RelayFilled", "Expected RelayFilled error");
    }
  });

  it("Closes the fill PDA after the fill", async () => {
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));

    const closeFillPdaAccounts = {
      state,
      signer: relayer.publicKey,
      fillStatus: accounts.fillStatus,
      systemProgram: anchor.web3.SystemProgram.programId,
    };

    // Execute the fill_v3_relay call
    await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);

    // Verify the fill PDA exists before closing
    const fillStatusAccountBefore = await connection.getAccountInfo(accounts.fillStatus);
    assert.isNotNull(fillStatusAccountBefore, "Fill PDA should exist before closing");

    // Attempt to close the fill PDA before the fill deadline should fail.
    try {
      await program.methods.closeFillPda(relayHash, relayData).accounts(closeFillPdaAccounts).signers([relayer]).rpc();
      assert.fail("Closing fill PDA should have failed before fill deadline");
    } catch (err: any) {
      assert.include(
        err.toString(),
        "CanOnlyCloseFillStatusPdaIfFillDeadlinePassed",
        "Expected CanOnlyCloseFillStatusPdaIfFillDeadlinePassed error"
      );
    }

    // Set the current time to past the fill deadline
    await setCurrentTime(program, state, relayer, new BN(relayData.fillDeadline + 1));

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
    await approvedFillV3Relay([Array.from(relayHash), relayData, new BN(1), relayer.publicKey]);

    // Fetch FillStatusAccount after fillV3Relay
    fillStatusAccount = await program.account.fillStatusAccount.fetch(fillStatusPDA);
    assert.isNotNull(fillStatusAccount, "FillStatusAccount should be initialized after fillV3Relay");
    assert.equal(JSON.stringify(fillStatusAccount.status), `{\"filled\":{}}`, "FillStatus should be Filled");
    assert.equal(fillStatusAccount.relayer.toString(), relayer.publicKey.toString(), "Caller should be set as relayer");
  });

  it("Fails to fill a relay when fills are paused", async () => {
    // Pause fills
    const pauseFillsAccounts = { state: state, signer: owner, program: program.programId };
    await program.methods.pauseFills(true).accounts(pauseFillsAccounts).rpc();
    const stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedFills, "Fills should be paused");

    // Try to fill the relay. This should fail because fills are paused.
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    try {
      await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);
      assert.fail("Should not be able to fill relay when fills are paused");
    } catch (err: any) {
      assert.include(err.toString(), "Fills are currently paused!", "Expected fills paused error");
    }
  });

  it("Fails to fill a relay to wrong recipient token account", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);

    // Create new accounts as derived from wrong recipient.
    const wrongRecipient = Keypair.generate().publicKey;
    const wrongRecipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, wrongRecipient)).address;
    const [wrongFillStatus] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId);

    try {
      await approvedFillV3Relay([Array.from(relayHash), relayData, new BN(1), relayer.publicKey], {
        ...accounts,
        recipientTokenAccount: wrongRecipientTA,
        fillStatus: wrongFillStatus,
      });
      assert.fail("Should not be able to fill relay to wrong recipient token account");
    } catch (err: any) {
      assert.include(err.toString(), "ConstraintTokenOwner", "Expected ConstraintTokenOwner error");
    }
  });

  it("Fails to fill a relay for mint inconsistent output_token", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);

    // Create and fund new accounts as derived from wrong mint account.
    const wrongMint = await createMint(connection, payer, owner, owner, tokenDecimals);
    const wrongRecipientTA = (await getOrCreateAssociatedTokenAccount(connection, payer, wrongMint, recipient)).address;
    const wrongRelayerTA = (await getOrCreateAssociatedTokenAccount(connection, payer, wrongMint, relayer.publicKey))
      .address;
    await mintTo(connection, payer, wrongMint, wrongRelayerTA, owner, seedBalance);

    try {
      await approvedFillV3Relay([Array.from(relayHash), relayData, new BN(1), relayer.publicKey], {
        ...accounts,
        mint: wrongMint,
        relayerTokenAccount: wrongRelayerTA,
        recipientTokenAccount: wrongRecipientTA,
      });
      assert.fail("Should not be able to process fill for inconsistent mint");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidMint", "Expected InvalidMint error");
    }
  });

  it("Self-relay does not invoke token transfer", async () => {
    // Set recipient to be the same as relayer.
    updateRelayData({ ...relayData, depositor: relayer.publicKey, recipient: relayer.publicKey });
    accounts.recipientTokenAccount = relayerTA;

    // Store relayer's balance before the fill
    const iRelayerBalance = (await getAccount(connection, relayerTA)).amount;

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));

    // No need for approval in self-relay.
    const txSignature = await program.methods
      .fillV3Relay(relayHash, relayData, new BN(1), relayer.publicKey)
      .accounts(accounts)
      .remainingAccounts(fillRemainingAccounts)
      .signers([relayer])
      .rpc();

    // Verify relayer's balance after the fill is unchanged
    const fRelayerBalance = (await getAccount(connection, relayerTA)).amount;
    assertSE(fRelayerBalance, iRelayerBalance, "Relayer's balance should not have changed");

    await new Promise((resolve) => setTimeout(resolve, 1000)); // Wait for tx processing
    const txResult = await connection.getTransaction(txSignature, {
      commitment: "confirmed",
      maxSupportedTransactionVersion: 0,
    });
    if (txResult === null || txResult.meta === null) throw new Error("Transaction meta not confirmed");
    if (txResult.meta.logMessages === null || txResult.meta.logMessages === undefined)
      throw new Error("Transaction logs not found");
    assert.isTrue(
      txResult.meta.logMessages.every((log) => !log.includes(`Program ${TOKEN_PROGRAM_ID} invoke`)),
      "Token Program should not be invoked"
    );
  });

  it("Fills a V3 relay from custom relayer token account", async () => {
    // Create and mint to custom relayer token account
    const customKeypair = Keypair.generate();
    const customRelayerTA = await createAccount(connection, payer, mint, relayer.publicKey, customKeypair);
    await mintTo(connection, payer, mint, customRelayerTA, owner, seedBalance);

    // Save balances before the the fill
    const iRelayerBal = (await getAccount(connection, customRelayerTA)).amount;
    const iRecipientBal = (await getAccount(connection, recipientTA)).amount;

    // Fill relay from custom relayer token account
    accounts.relayerTokenAccount = customRelayerTA;
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);

    // Verify balances after the fill
    const fRelayerBal = (await getAccount(connection, customRelayerTA)).amount;
    const fRecipientBal = (await getAccount(connection, recipientTA)).amount;
    assertSE(fRelayerBal, iRelayerBal - BigInt(relayAmount), "Relayer's balance should be reduced by the relay amount");
    assertSE(
      fRecipientBal,
      iRecipientBal + BigInt(relayAmount),
      "Recipient's balance should be increased by the relay amount"
    );
  });
  it("Fills a deposit for a recipient without an existing ATA", async () => {
    // Generate a new recipient account
    const newRecipient = Keypair.generate().publicKey;
    const newRecipientATA = getAssociatedTokenAddressSync(mint, newRecipient);

    // Attempt to fill a deposit, expecting failure due to missing ATA
    const newRelayData = {
      ...relayData,
      recipient: newRecipient,
      depositId: intToU8Array32(Math.floor(Math.random() * 1000000)),
    };
    updateRelayData(newRelayData);
    accounts.recipientTokenAccount = newRecipientATA;
    const relayHash = Array.from(calculateRelayHashUint8Array(newRelayData, chainId));

    try {
      await approvedFillV3Relay([relayHash, newRelayData, new BN(1), relayer.publicKey]);
      assert.fail("Fill should have failed due to missing ATA");
    } catch (err: any) {
      assert.include(err.toString(), "AccountNotInitialized", "Expected AccountNotInitialized error");
    }

    // Create the ATA using the create_token_accounts method
    const createTokenAccountsInstruction = await program.methods
      .createTokenAccounts()
      .accounts({ signer: relayer.publicKey, mint, tokenProgram: TOKEN_PROGRAM_ID })
      .remainingAccounts([
        { pubkey: newRecipient, isWritable: false, isSigner: false },
        { pubkey: newRecipientATA, isWritable: true, isSigner: false },
      ])
      .instruction();

    // Fill the deposit in the same transaction
    const approveInstruction = await createApproveCheckedInstruction(
      accounts.relayerTokenAccount,
      accounts.mint,
      accounts.state,
      accounts.signer,
      BigInt(newRelayData.outputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );
    const fillInstruction = await program.methods
      .fillV3Relay(relayHash, newRelayData, new BN(1), relayer.publicKey)
      .accounts(accounts)
      .remainingAccounts(fillRemainingAccounts)
      .instruction();

    // Create and send the transaction
    const transaction = new web3.Transaction().add(createTokenAccountsInstruction, approveInstruction, fillInstruction);
    await web3.sendAndConfirmTransaction(connection, transaction, [relayer]);

    // Verify the recipient's balance after the fill
    const recipientAccount = await getAccount(connection, newRecipientATA);
    assertSE(recipientAccount.amount, relayAmount, "Recipient's balance should be increased by the relay amount");
  });
  it("Max fills in one transaction with account creation", async () => {
    // Save relayer balance before the the fills
    const iRelayerBal = (await getAccount(connection, relayerTA)).amount;

    // Larger number of fills would exceed the transaction size limit.
    const numberOfFills = 2;

    // Build instruction for all recipient ATA creation
    const recipientAuthorities = Array.from({ length: numberOfFills }, () => Keypair.generate().publicKey);
    const recipientAssociatedTokens = recipientAuthorities.map((authority) =>
      getAssociatedTokenAddressSync(mint, authority)
    );
    const createTAremainingAccounts = recipientAuthorities.flatMap((authority, index) => [
      { pubkey: authority, isWritable: false, isSigner: false },
      { pubkey: recipientAssociatedTokens[index], isWritable: true, isSigner: false },
    ]);
    const createTokenAccountsInstruction = await program.methods
      .createTokenAccounts()
      .accounts({ signer: relayer.publicKey, mint, tokenProgram: TOKEN_PROGRAM_ID })
      .remainingAccounts(createTAremainingAccounts)
      .instruction();

    // Build instructions for all fills
    let totalFillAmount = new BN(0);
    const fillInstructions: TransactionInstruction[] = [];
    for (let i = 0; i < numberOfFills; i++) {
      const newRelayData = {
        ...relayData,
        recipient: recipientAuthorities[i],
        depositId: intToU8Array32(Math.floor(Math.random() * 1000000)),
      };
      totalFillAmount = totalFillAmount.add(newRelayData.outputAmount);
      updateRelayData(newRelayData);
      accounts.recipientTokenAccount = recipientAssociatedTokens[i];
      const relayHash = Array.from(calculateRelayHashUint8Array(newRelayData, chainId));
      const fillInstruction = await program.methods
        .fillV3Relay(relayHash, newRelayData, new BN(1), relayer.publicKey)
        .accounts(accounts)
        .remainingAccounts(fillRemainingAccounts)
        .instruction();
      fillInstructions.push(fillInstruction);
    }

    const approveInstruction = await createApproveCheckedInstruction(
      accounts.relayerTokenAccount,
      accounts.mint,
      accounts.state,
      accounts.signer,
      BigInt(totalFillAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );

    // Fill using the ALT.
    await sendTransactionWithLookupTable(
      connection,
      [createTokenAccountsInstruction, approveInstruction, ...fillInstructions],
      relayer
    );

    // Verify balances after the fill
    await new Promise((resolve) => setTimeout(resolve, 1000)); // Wait for tx processing
    const fRelayerBal = (await getAccount(connection, relayerTA)).amount;
    assertSE(
      fRelayerBal,
      iRelayerBal - BigInt(relayAmount * numberOfFills),
      "Relayer's balance should be reduced by total relay amount"
    );
    recipientAssociatedTokens.forEach(async (recipientAssociatedToken) => {
      const recipientBal = (await getAccount(connection, recipientAssociatedToken)).amount;
      assertSE(recipientBal, BigInt(relayAmount), "Recipient's balance should be increased by the relay amount");
    });
  });

  it("Fills a V3 relay with enabled CPI-guard", async () => {
    // CPI-guard is available only for the 2022 token program.
    tokenProgram = TOKEN_2022_PROGRAM_ID;

    // Remint the tokens on the token 2022 program.
    mint = await createMint(connection, payer, owner, owner, tokenDecimals, undefined, undefined, tokenProgram);
    recipientTA = (
      await getOrCreateAssociatedTokenAccount(
        connection,
        payer,
        mint,
        recipient,
        undefined,
        undefined,
        undefined,
        tokenProgram
      )
    ).address;
    relayerTA = (
      await getOrCreateAssociatedTokenAccount(
        connection,
        payer,
        mint,
        relayer.publicKey,
        undefined,
        undefined,
        undefined,
        tokenProgram
      )
    ).address;
    await mintTo(connection, payer, mint, relayerTA, owner, seedBalance, undefined, undefined, tokenProgram);

    // Update relay data with new mint.
    relayData.outputToken = mint;
    updateRelayData(relayData);

    // Enable CPI-guard for the relayer (requires TA reallocation).
    const enableCpiGuardTx = new Transaction().add(
      createReallocateInstruction(relayerTA, relayer.publicKey, [ExtensionType.CpiGuard], relayer.publicKey),
      createEnableCpiGuardInstruction(relayerTA, relayer.publicKey)
    );
    await sendAndConfirmTransaction(connection, enableCpiGuardTx, [relayer]);

    // Verify recipient's balance before the fill
    let recipientAccount = await getAccount(connection, recipientTA, undefined, tokenProgram);
    assertSE(recipientAccount.amount, "0", "Recipient's balance should be 0 before the fill");

    // Verify relayer's balance before the fill
    let relayerAccount = await getAccount(connection, relayerTA, undefined, tokenProgram);
    assertSE(relayerAccount.amount, seedBalance, "Relayer's balance should be equal to seed balance before the fill");

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillV3Relay([relayHash, relayData, new BN(1), relayer.publicKey]);

    // Verify relayer's balance after the fill
    relayerAccount = await getAccount(connection, relayerTA, undefined, tokenProgram);
    assertSE(
      relayerAccount.amount,
      seedBalance - relayAmount,
      "Relayer's balance should be reduced by the relay amount"
    );

    // Verify recipient's balance after the fill
    recipientAccount = await getAccount(connection, recipientTA, undefined, tokenProgram);
    assertSE(recipientAccount.amount, relayAmount, "Recipient's balance should be increased by the relay amount");
  });

  it("Emits zeroed hash for empty message", async () => {
    updateRelayData({ ...relayData, message: Buffer.alloc(0) });
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillV3Relay([relayHash, relayData, new BN(420), otherRelayer.publicKey]);

    // Fetch and verify the FilledV3Relay event
    await new Promise((resolve) => setTimeout(resolve, 500));
    const events = await readProgramEvents(connection, program);
    const event = events.find((event) => event.name === "filledV3Relay").data;
    assert.isNotNull(event, "FilledV3Relay event should be emitted");

    // Verify that the event data has zeroed message hash.
    assertSE(event.messageHash, new Uint8Array(32), `MessageHash should be zeroed`);
    assertSE(event.relayExecutionInfo.updatedMessageHash, new Uint8Array(32), `UpdatedMessageHash should be zeroed`);
  });
});
