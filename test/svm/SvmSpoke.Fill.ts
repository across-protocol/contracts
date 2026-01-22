import * as anchor from "@coral-xyz/anchor";
import { BN, web3 } from "@coral-xyz/anchor";
import { getApproveCheckedInstruction } from "@solana-program/token";
import {
  AccountRole,
  Address,
  address,
  AddressesByLookupTableAddress,
  appendTransactionMessageInstruction,
  createKeyPairFromBytes,
  createSignerFromKeyPair,
  getProgramDerivedAddress,
  IAccountMeta,
  pipe,
} from "@solana/kit";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createAccount,
  createApproveCheckedInstruction,
  createEnableCpiGuardInstruction,
  createMint,
  createReallocateInstruction,
  ExtensionType,
  getAccount,
  getAssociatedTokenAddressSync,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  TOKEN_2022_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { Keypair, PublicKey, sendAndConfirmTransaction, Transaction, TransactionInstruction } from "@solana/web3.js";
import {
  createLookupTable,
  createDefaultTransaction,
  extendLookupTable,
  sendTransactionWithLookupTable,
  signAndSendTransaction,
  SvmSpokeClient,
} from "../../src/svm";
import { FillRelayAsyncInput } from "../../src/svm/clients/SvmSpoke";
import {
  calculateRelayHashUint8Array,
  hashNonEmptyMessage,
  intToU8Array32,
  getFillRelayDelegatePda,
  readEventsUntilFound,
  sendTransactionWithLookupTable as sendTransactionWithLookupTableV1,
} from "../../src/svm/web3-v1";
import { FillDataValues, RelayData } from "../../src/types/svm";
import { common } from "./SvmSpoke.common";
import { createDefaultSolanaClient, testAcrossPlusMessage } from "./utils";
const {
  provider,
  connection,
  program,
  owner,
  chainId,
  seedBalance,
  recipient,
  initializeState,
  setCurrentTime,
  assertSE,
  assert,
} = common;

describe("svm_spoke.fill", () => {
  anchor.setProvider(provider);
  const { payer } = anchor.AnchorProvider.env().wallet as anchor.Wallet;
  const relayer = Keypair.generate();
  const otherRelayer = Keypair.generate();
  const { encodedMessage, fillRemainingAccounts } = testAcrossPlusMessage();
  const tokenDecimals = 6;

  let state: PublicKey,
    mint: PublicKey,
    relayerTA: PublicKey,
    recipientTA: PublicKey,
    otherRelayerTA: PublicKey,
    tokenProgram: PublicKey,
    seed: BN;

  const relayAmount = 500000;
  let relayData: RelayData; // reused relay data for all tests.

  type FillAccounts = {
    state: PublicKey;
    delegate: PublicKey;
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

  const updateRelayData = (newRelayData: RelayData) => {
    relayData = newRelayData;
    const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync(
      [Buffer.from("fills"), relayHashUint8Array],
      program.programId
    );

    const { pda: delegatePda } = getFillRelayDelegatePda(
      relayHashUint8Array,
      new BN(1),
      relayer.publicKey,
      program.programId
    );

    accounts = {
      state,
      delegate: delegatePda,
      signer: relayer.publicKey,
      instructionParams: program.programId,
      mint,
      relayerTokenAccount: relayerTA,
      recipientTokenAccount: recipientTA,
      fillStatus: fillStatusPDA,
      tokenProgram: tokenProgram ?? TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };
  };

  const approvedFillRelay = async (
    fillDataValues: FillDataValues,
    calledFillAccounts: FillAccounts = accounts,
    callingRelayer: Keypair = relayer
  ): Promise<string> => {
    const relayHash = Uint8Array.from(fillDataValues[0]);
    const { seedHash, pda: delegatePda } = getFillRelayDelegatePda(
      relayHash,
      fillDataValues[2],
      fillDataValues[3],
      program.programId
    );

    const approveIx = await createApproveCheckedInstruction(
      calledFillAccounts.relayerTokenAccount,
      calledFillAccounts.mint,
      delegatePda,
      calledFillAccounts.signer,
      BigInt(fillDataValues[1].outputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );

    const fillIx = await program.methods
      .fillRelay(...fillDataValues)
      .accounts({ ...calledFillAccounts, delegate: delegatePda })
      .remainingAccounts(fillRemainingAccounts)
      .instruction();

    return sendAndConfirmTransaction(connection, new Transaction().add(approveIx, fillIx), [payer, callingRelayer]);
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
    ({ state, seed } = await initializeState());
    tokenProgram = TOKEN_PROGRAM_ID; // Some tests might override this.

    const initialRelayData = {
      depositor: recipient,
      recipient: recipient,
      exclusiveRelayer: relayer.publicKey,
      inputToken: mint, // This is lazy. it should be an encoded token from a separate domain most likely.
      outputToken: mint,
      inputAmount: intToU8Array32(relayAmount),
      outputAmount: new BN(relayAmount),
      originChainId: new BN(1),
      depositId: intToU8Array32(Math.floor(Math.random() * 1000000)), // force that we always have a new deposit id.
      fillDeadline: Math.floor(Date.now() / 1000) + 60, // 1 minute from now
      exclusivityDeadline: Math.floor(Date.now() / 1000) + 30, // 30 seconds from now
      message: encodedMessage,
    };

    updateRelayData(initialRelayData);
  });

  it("Fills a relay and verifies balances", async () => {
    // Verify recipient's balance before the fill
    let recipientAccount = await getAccount(connection, recipientTA);
    assertSE(recipientAccount.amount, "0", "Recipient's balance should be 0 before the fill");

    // Verify relayer's balance before the fill
    let relayerAccount = await getAccount(connection, relayerTA);
    assertSE(relayerAccount.amount, seedBalance, "Relayer's balance should be equal to seed balance before the fill");

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    await approvedFillRelay([relayHash, relayData, chainId, relayer.publicKey]);

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

  it("Verifies FilledRelay event after filling a relay", async () => {
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    const tx = await approvedFillRelay([relayHash, relayData, new BN(420), otherRelayer.publicKey]);

    // Fetch and verify the FilledRelay event
    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events.find((event) => event.name === "filledRelay")?.data;
    assert.isNotNull(event, "FilledRelay event should be emitted");

    // Verify that the event data matches the relay data.
    Object.entries(relayData).forEach(([key, value]) => {
      if (key === "message") {
        assertSE(event.messageHash, hashNonEmptyMessage(value as Buffer), `MessageHash should match`);
      } else {
        assertSE(event[key], value, `${key.charAt(0).toUpperCase() + key.slice(1)} should match`);
      }
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

  it("Fails to fill a relay after the fill deadline", async () => {
    updateRelayData({ ...relayData, fillDeadline: Math.floor(Date.now() / 1000) - 69 }); // 69 seconds ago

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    try {
      await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);
      assert.fail("Fill should have failed due to fill deadline passed");
    } catch (err: any) {
      assert.include(err.toString(), "ExpiredFillDeadline", "Expected ExpiredFillDeadline error");
    }
  });

  it("Fails to fill a relay by non-exclusive relayer before exclusivity deadline", async () => {
    accounts.signer = otherRelayer.publicKey;
    accounts.relayerTokenAccount = otherRelayerTA;

    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));
    try {
      await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey], undefined, otherRelayer);
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
    await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey], undefined, otherRelayer);

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

  it("Fails to fill a relay with the same deposit data multiple times", async () => {
    const relayHash = Array.from(calculateRelayHashUint8Array(relayData, chainId));

    // First fill attempt
    await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);

    // Second fill attempt with the same data
    try {
      await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);
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

    // Execute the fill_relay call
    await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);

    // Verify the fill PDA exists before closing
    const fillStatusAccountBefore = await connection.getAccountInfo(accounts.fillStatus);
    assert.isNotNull(fillStatusAccountBefore, "Fill PDA should exist before closing");

    // Attempt to close the fill PDA before the fill deadline should fail.
    try {
      await program.methods.closeFillPda().accounts(closeFillPdaAccounts).signers([relayer]).rpc();
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
    await program.methods.closeFillPda().accounts(closeFillPdaAccounts).signers([relayer]).rpc();

    // Verify the fill PDA is closed
    const fillStatusAccountAfter = await connection.getAccountInfo(accounts.fillStatus);
    assert.isNull(fillStatusAccountAfter, "Fill PDA should be closed after closing");
  });

  it("Fetches FillStatusAccount before and after fillRelay", async () => {
    const relayHash = calculateRelayHashUint8Array(relayData, chainId);
    const [fillStatusPDA] = PublicKey.findProgramAddressSync([Buffer.from("fills"), relayHash], program.programId);

    // Fetch FillStatusAccount before fillRelay
    let fillStatusAccount = await program.account.fillStatusAccount.fetchNullable(fillStatusPDA);
    assert.isNull(fillStatusAccount, "FillStatusAccount should be uninitialized before fillRelay");

    // Fill the relay
    await approvedFillRelay([Array.from(relayHash), relayData, new BN(1), relayer.publicKey]);

    // Fetch FillStatusAccount after fillRelay
    fillStatusAccount = await program.account.fillStatusAccount.fetch(fillStatusPDA);
    assert.isNotNull(fillStatusAccount, "FillStatusAccount should be initialized after fillRelay");
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
      await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);
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
      await approvedFillRelay([Array.from(relayHash), relayData, new BN(1), relayer.publicKey], {
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
      await approvedFillRelay([Array.from(relayHash), relayData, new BN(1), relayer.publicKey], {
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

  it("Fills a relay from custom relayer token account", async () => {
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
    await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);

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
    const relayHashUint8Array = calculateRelayHashUint8Array(newRelayData, chainId);
    const relayHash = Array.from(relayHashUint8Array);

    try {
      await approvedFillRelay([relayHash, newRelayData, new BN(1), relayer.publicKey]);
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

    const { pda: delegatePda } = getFillRelayDelegatePda(
      relayHashUint8Array,
      new BN(1),
      relayer.publicKey,
      program.programId
    );

    // Fill the deposit in the same transaction
    const approveInstruction = await createApproveCheckedInstruction(
      accounts.relayerTokenAccount,
      accounts.mint,
      delegatePda,
      accounts.signer,
      BigInt(newRelayData.outputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );
    const fillInstruction = await program.methods
      .fillRelay(relayHash, newRelayData, new BN(1), relayer.publicKey)
      .accounts({ ...accounts, delegate: delegatePda })
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
    const approveAndfillInstructions: TransactionInstruction[] = [];
    for (let i = 0; i < numberOfFills; i++) {
      const newRelayData = {
        ...relayData,
        recipient: recipientAuthorities[i],
        depositId: intToU8Array32(Math.floor(Math.random() * 1000000)),
      };
      totalFillAmount = totalFillAmount.add(newRelayData.outputAmount);
      updateRelayData(newRelayData);
      accounts.recipientTokenAccount = recipientAssociatedTokens[i];
      const relayHashUint8Array = calculateRelayHashUint8Array(newRelayData, chainId);
      const relayHash = Array.from(relayHashUint8Array);

      const { pda: delegatePda } = getFillRelayDelegatePda(
        relayHashUint8Array,
        new BN(1),
        relayer.publicKey,
        program.programId
      );

      const approveInstruction = await createApproveCheckedInstruction(
        accounts.relayerTokenAccount,
        accounts.mint,
        delegatePda,
        accounts.signer,
        BigInt(totalFillAmount.toString()),
        tokenDecimals,
        undefined,
        tokenProgram
      );
      approveAndfillInstructions.push(approveInstruction);

      const fillInstruction = await program.methods
        .fillRelay(relayHash, newRelayData, new BN(1), relayer.publicKey)
        .accounts({ ...accounts, delegate: delegatePda })
        .remainingAccounts(fillRemainingAccounts)
        .instruction();
      approveAndfillInstructions.push(fillInstruction);
    }

    // Fill using the ALT.
    await sendTransactionWithLookupTableV1(
      connection,
      [createTokenAccountsInstruction, ...approveAndfillInstructions],
      relayer
    );

    // Verify balances after the fill
    await new Promise((resolve) => setTimeout(resolve, 500)); // Wait for tx processing
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

  it("Fills a relay with enabled CPI-guard", async () => {
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
    await approvedFillRelay([relayHash, relayData, new BN(1), relayer.publicKey]);

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
    const tx = await approvedFillRelay([relayHash, relayData, new BN(420), otherRelayer.publicKey]);

    // Fetch and verify the FilledRelay event
    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events.find((event) => event.name === "filledRelay")?.data;
    assert.isNotNull(event, "FilledRelay event should be emitted");

    // Verify that the event data has zeroed message hash.
    assertSE(event.messageHash, new Uint8Array(32), `MessageHash should be zeroed`);
    assertSE(event.relayExecutionInfo.updatedMessageHash, new Uint8Array(32), `UpdatedMessageHash should be zeroed`);
  });

  describe("codama client and solana kit", () => {
    it("Fills a V3 relay and verifies balances with codama client and solana kit", async () => {
      const rpcClient = createDefaultSolanaClient();
      const signer = await createSignerFromKeyPair(await createKeyPairFromBytes(relayer.secretKey));

      const [eventAuthority] = await getProgramDerivedAddress({
        programAddress: address(program.programId.toString()),
        seeds: ["__event_authority"],
      });

      let recipientAccount = await getAccount(connection, recipientTA);
      assertSE(recipientAccount.amount, "0", "Recipient's balance should be 0 before the fill");

      let relayerAccount = await getAccount(connection, relayerTA);
      assertSE(relayerAccount.amount, seedBalance, "Relayer's balance should be equal to seed balance before the fill");

      const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
      const relayHash = Array.from(relayHashUint8Array);
      const delegate = address(
        getFillRelayDelegatePda(relayHashUint8Array, new BN(1), relayer.publicKey, program.programId).pda.toString()
      );

      const formattedAccounts = {
        state: address(accounts.state.toString()),
        delegate,
        instructionParams: address(program.programId.toString()),
        mint: address(mint.toString()),
        relayerTokenAccount: address(relayerTA.toString()),
        recipientTokenAccount: address(recipientTA.toString()),
        fillStatus: address(accounts.fillStatus.toString()),
        tokenProgram: address(TOKEN_PROGRAM_ID.toString()),
        associatedTokenProgram: address(ASSOCIATED_TOKEN_PROGRAM_ID.toString()),
        systemProgram: address(anchor.web3.SystemProgram.programId.toString()),
        program: address(program.programId.toString()),
        eventAuthority,
        signer,
      };

      const formattedRelayData = {
        relayHash: new Uint8Array(relayHash),
        relayData: {
          depositor: address(relayData.depositor.toString()),
          recipient: address(relayData.recipient.toString()),
          exclusiveRelayer: address(relayData.exclusiveRelayer.toString()),
          inputToken: address(relayData.inputToken.toString()),
          outputToken: address(relayData.outputToken.toString()),
          inputAmount: new Uint8Array(relayData.inputAmount),
          outputAmount: relayData.outputAmount.toNumber(),
          originChainId: relayData.originChainId.toNumber(),
          depositId: new Uint8Array(relayData.depositId),
          fillDeadline: relayData.fillDeadline,
          exclusivityDeadline: relayData.exclusivityDeadline,
          message: relayData.message,
        },
        repaymentChainId: 1,
        repaymentAddress: address(relayer.publicKey.toString()),
      };

      const approveIx = getApproveCheckedInstruction({
        source: address(accounts.relayerTokenAccount.toString()),
        mint: address(accounts.mint.toString()),
        delegate,
        owner: address(accounts.signer.toString()),
        amount: BigInt(relayData.outputAmount.toString()),
        decimals: tokenDecimals,
      });

      const fillRelayInput: FillRelayAsyncInput = {
        ...formattedRelayData,
        ...formattedAccounts,
      };

      const fillRelayIxData = await SvmSpokeClient.getFillRelayInstructionAsync(fillRelayInput);
      const fillRelayIx = {
        ...fillRelayIxData,
        accounts: fillRelayIxData.accounts.map((account) =>
          account.address === program.programId.toString() ? { ...account, role: AccountRole.READONLY } : account
        ),
      };
      const remainingAccounts: IAccountMeta<string>[] = fillRemainingAccounts.map((account) => ({
        address: address(account.pubkey.toString()),
        role: AccountRole.WRITABLE,
      }));
      (fillRelayIx.accounts as IAccountMeta<string>[]).push(...remainingAccounts);

      const tx = await pipe(
        await createDefaultTransaction(rpcClient, signer),
        (tx) => appendTransactionMessageInstruction(approveIx, tx),
        (tx) => appendTransactionMessageInstruction(fillRelayIx, tx),
        (tx) => signAndSendTransaction(rpcClient, tx)
      );

      const events = await readEventsUntilFound(connection, tx, [program]);
      const event = events.find((event) => event.name === "filledRelay")?.data;
      assert.isNotNull(event, "FilledRelay event should be emitted");

      relayerAccount = await getAccount(connection, relayerTA);
      assertSE(
        relayerAccount.amount,
        seedBalance - relayAmount,
        "Relayer's balance should be reduced by the relay amount"
      );

      recipientAccount = await getAccount(connection, recipientTA);
      assertSE(recipientAccount.amount, relayAmount, "Recipient's balance should be increased by the relay amount");
    });
    it("Fills a V3 relay with ALT", async () => {
      const rpcClient = createDefaultSolanaClient();
      const signer = await createSignerFromKeyPair(await createKeyPairFromBytes(relayer.secretKey));

      const [eventAuthority] = await getProgramDerivedAddress({
        programAddress: address(program.programId.toString()),
        seeds: ["__event_authority"],
      });

      let recipientAccount = await getAccount(connection, recipientTA);
      assertSE(recipientAccount.amount, "0", "Recipient's balance should be 0 before the fill");

      let relayerAccount = await getAccount(connection, relayerTA);
      assertSE(relayerAccount.amount, seedBalance, "Relayer's balance should be equal to seed balance before the fill");

      const relayHashUint8Array = calculateRelayHashUint8Array(relayData, chainId);
      const relayHash = Array.from(relayHashUint8Array);
      const delegate = address(
        getFillRelayDelegatePda(relayHashUint8Array, new BN(1), relayer.publicKey, program.programId).pda.toString()
      );

      const formattedAccounts = {
        state: address(accounts.state.toString()),
        delegate,
        instructionParams: address(program.programId.toString()),
        mint: address(mint.toString()),
        relayerTokenAccount: address(relayerTA.toString()),
        recipientTokenAccount: address(recipientTA.toString()),
        fillStatus: address(accounts.fillStatus.toString()),
        tokenProgram: address(TOKEN_PROGRAM_ID.toString()),
        associatedTokenProgram: address(ASSOCIATED_TOKEN_PROGRAM_ID.toString()),
        systemProgram: address(anchor.web3.SystemProgram.programId.toString()),
        program: address(program.programId.toString()),
        eventAuthority,
        signer,
      };

      const formattedRelayData = {
        relayHash: new Uint8Array(relayHash),
        relayData: {
          depositor: address(relayData.depositor.toString()),
          recipient: address(relayData.recipient.toString()),
          exclusiveRelayer: address(relayData.exclusiveRelayer.toString()),
          inputToken: address(relayData.inputToken.toString()),
          outputToken: address(relayData.outputToken.toString()),
          inputAmount: new Uint8Array(relayData.inputAmount),
          outputAmount: relayData.outputAmount.toNumber(),
          originChainId: relayData.originChainId.toNumber(),
          depositId: new Uint8Array(relayData.depositId),
          fillDeadline: relayData.fillDeadline,
          exclusivityDeadline: relayData.exclusivityDeadline,
          message: relayData.message,
        },
        repaymentChainId: 1,
        repaymentAddress: address(relayer.publicKey.toString()),
      };

      const approveIx = getApproveCheckedInstruction({
        source: address(accounts.relayerTokenAccount.toString()),
        mint: address(accounts.mint.toString()),
        delegate,
        owner: address(accounts.signer.toString()),
        amount: BigInt(relayData.outputAmount.toString()),
        decimals: tokenDecimals,
      });

      const fillRelayInput: FillRelayAsyncInput = {
        ...formattedRelayData,
        ...formattedAccounts,
      };

      const fillRelayIxData = await SvmSpokeClient.getFillRelayInstructionAsync(fillRelayInput);
      const fillRelayIx = {
        ...fillRelayIxData,
        accounts: fillRelayIxData.accounts.map((account) =>
          account.address === program.programId.toString() ? { ...account, role: AccountRole.READONLY } : account
        ),
      };
      const remainingAccounts: IAccountMeta<string>[] = fillRemainingAccounts.map((account) => ({
        address: address(account.pubkey.toString()),
        role: AccountRole.WRITABLE,
      }));
      (fillRelayIx.accounts as IAccountMeta<string>[]).push(...remainingAccounts);

      const alt = await createLookupTable(rpcClient, signer);

      const ac: Address[] = [
        formattedAccounts.state,
        formattedAccounts.delegate,
        formattedAccounts.instructionParams,
        formattedAccounts.mint,
        formattedAccounts.relayerTokenAccount,
        formattedAccounts.recipientTokenAccount,
        formattedAccounts.fillStatus,
        formattedAccounts.tokenProgram,
        formattedAccounts.associatedTokenProgram,
        formattedAccounts.systemProgram,
        formattedAccounts.program,
        formattedAccounts.eventAuthority,
        ...remainingAccounts.map((account) => account.address),
      ];
      const lookupTableAddresses: AddressesByLookupTableAddress = {
        [alt]: ac,
      };
      await extendLookupTable(rpcClient, signer, alt, ac);

      const tx = await sendTransactionWithLookupTable(
        rpcClient,
        signer,
        [approveIx, fillRelayIx],
        lookupTableAddresses
      );

      const events = await readEventsUntilFound(connection, tx, [program]);
      const event = events.find((event) => event.name === "filledRelay")?.data;
      assert.isNotNull(event, "FilledRelay event should be emitted");

      relayerAccount = await getAccount(connection, relayerTA);
      assertSE(
        relayerAccount.amount,
        seedBalance - relayAmount,
        "Relayer's balance should be reduced by the relay amount"
      );

      recipientAccount = await getAccount(connection, recipientTA);
      assertSE(recipientAccount.amount, relayAmount, "Recipient's balance should be increased by the relay amount");
    });
  });
});
