import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import { getApproveCheckedInstruction } from "@solana-program/token";
import {
  address,
  airdropFactory,
  appendTransactionMessageInstruction,
  createKeyPairFromBytes,
  createSignerFromKeyPair,
  getProgramDerivedAddress,
  lamports,
  pipe,
} from "@solana/kit";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  ExtensionType,
  NATIVE_MINT,
  TOKEN_2022_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createApproveCheckedInstruction,
  createAssociatedTokenAccountIdempotentInstruction,
  createCloseAccountInstruction,
  createEnableCpiGuardInstruction,
  createMint,
  createReallocateInstruction,
  createSyncNativeInstruction,
  getAccount,
  getAssociatedTokenAddressSync,
  getMinimumBalanceForRentExemptAccount,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import { Keypair, PublicKey, SystemProgram, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { BigNumber, ethers } from "ethers";
import { SvmSpokeClient, createDefaultTransaction, signAndSendTransaction } from "../../src/svm";
import { DepositInput } from "../../src/svm/clients/SvmSpoke";
import {
  getDepositNowPda,
  getDepositNowSeedHash,
  getDepositPda,
  getDepositSeedHash,
  intToU8Array32,
  readEventsUntilFound,
  u8Array32ToBigNumber,
  u8Array32ToInt,
} from "../../src/svm/web3-v1";
import { DepositData, DepositDataValues } from "../../src/types/svm";
import { MAX_EXCLUSIVITY_OFFSET_SECONDS } from "../../test-utils";
import { common } from "./SvmSpoke.common";
import { createDefaultSolanaClient } from "./utils";
const {
  provider,
  connection,
  program,
  owner,
  seedBalance,
  initializeState,
  depositData,
  assertSE,
  assert,
  getCurrentTime,
  depositQuoteTimeBuffer,
  fillDeadlineBuffer,
  getOrCreateVaultAta,
} = common;

const maxExclusivityOffsetSeconds = new BN(MAX_EXCLUSIVITY_OFFSET_SECONDS); // 1 year in seconds

type DepositDataSeed = Parameters<typeof getDepositSeedHash>[0];
type DepositNowDataSeed = Parameters<typeof getDepositNowSeedHash>[0];

describe("svm_spoke.deposit", () => {
  anchor.setProvider(provider);

  const depositor = Keypair.generate();
  const { payer } = anchor.AnchorProvider.env().wallet as anchor.Wallet;
  const tokenDecimals = 6;

  let state: PublicKey, inputToken: PublicKey, depositorTA: PublicKey, vault: PublicKey, tokenProgram: PublicKey;
  let seed: BN;

  // Re-used between tests to simplify props.
  type DepositAccounts = {
    state: PublicKey;
    delegate: PublicKey;
    signer: PublicKey;
    depositorTokenAccount: PublicKey;
    vault: PublicKey;
    mint: PublicKey;
    tokenProgram: PublicKey;
    program: PublicKey;
  };
  let depositAccounts: DepositAccounts;

  const setupInputToken = async () => {
    inputToken = await createMint(connection, payer, owner, owner, tokenDecimals, undefined, undefined, tokenProgram);

    depositorTA = (
      await getOrCreateAssociatedTokenAccount(
        connection,
        payer,
        inputToken,
        depositor.publicKey,
        undefined,
        undefined,
        undefined,
        tokenProgram
      )
    ).address;
    await mintTo(connection, payer, inputToken, depositorTA, owner, seedBalance, undefined, undefined, tokenProgram);
  };

  const createVault = async () => {
    vault = await getOrCreateVaultAta(payer, inputToken, state);

    // Set known fields in the depositData.
    depositData.depositor = depositor.publicKey;
    depositData.inputToken = inputToken;

    depositAccounts = {
      state,
      delegate: getDepositPda(depositData as DepositDataSeed, program.programId),
      signer: depositor.publicKey,
      depositorTokenAccount: depositorTA,
      vault,
      mint: inputToken,
      tokenProgram: tokenProgram ?? TOKEN_PROGRAM_ID,
      program: program.programId,
    };
  };

  const approvedDeposit = async (
    depositData: DepositData,
    calledDepositAccounts: DepositAccounts = depositAccounts
  ) => {
    const delegatePda = getDepositPda(depositData as DepositDataSeed, program.programId);
    calledDepositAccounts.delegate = delegatePda;

    // Delegate delegate PDA to pull depositor tokens.
    const approveIx = await createApproveCheckedInstruction(
      calledDepositAccounts.depositorTokenAccount,
      calledDepositAccounts.mint,
      delegatePda,
      depositor.publicKey,
      BigInt(depositData.inputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );
    const depositIx = await program.methods
      .deposit(
        depositData.depositor!,
        depositData.recipient,
        depositData.inputToken!,
        depositData.outputToken,
        depositData.inputAmount,
        depositData.outputAmount,
        depositData.destinationChainId,
        depositData.exclusiveRelayer,
        depositData.quoteTimestamp.toNumber(),
        depositData.fillDeadline.toNumber(),
        depositData.exclusivityParameter.toNumber(),
        depositData.message
      )
      .accounts(calledDepositAccounts)
      .instruction();
    const depositTx = new Transaction().add(approveIx, depositIx);
    return sendAndConfirmTransaction(connection, depositTx, [depositor]);
  };

  before(async () => {
    await connection.requestAirdrop(depositor.publicKey, 10_000_000_000); // 10 SOL
  });

  beforeEach(async () => {
    ({ state, seed } = await initializeState());

    tokenProgram = TOKEN_PROGRAM_ID; // Some tests might override this.
    await setupInputToken();

    await createVault();
  });

  it("Deposits tokens via deposit function and checks balances", async () => {
    // Verify vault balance is zero before the deposit
    let vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, "0", "Vault balance should be zero before the deposit");

    // Execute the deposit call
    await approvedDeposit(depositData);

    // Verify tokens leave the depositor's account
    let depositorAccount = await getAccount(connection, depositorTA);
    assertSE(
      depositorAccount.amount,
      seedBalance - depositData.inputAmount.toNumber(),
      "Depositor's balance should be reduced by the deposited amount"
    );

    // Verify tokens are credited into the vault
    vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, depositData.inputAmount, "Vault balance should be increased by the deposited amount");

    // Modify depositData for the second deposit
    const secondInputAmount = new BN(300000);

    // Execute the second deposit call
    await approvedDeposit({ ...depositData, inputAmount: secondInputAmount });

    // Verify tokens leave the depositor's account again
    depositorAccount = await getAccount(connection, depositorTA);
    assertSE(
      depositorAccount.amount,
      seedBalance - depositData.inputAmount.toNumber() - secondInputAmount.toNumber(),
      "Depositor's balance should be reduced by the total deposited amount"
    );

    // Verify tokens are credited into the vault again
    vaultAccount = await getAccount(connection, vault);
    assertSE(
      vaultAccount.amount,
      depositData.inputAmount.add(secondInputAmount),
      "Vault balance should be increased by the total deposited amount"
    );
  });

  it("Verifies FundsDeposited after deposits", async () => {
    depositData.inputAmount = depositData.inputAmount.add(new BN(69));

    // Execute the first deposit call
    const tx = await approvedDeposit(depositData);

    let events = await readEventsUntilFound(connection, tx, [program]);
    let event = events[0].data; // 0th event is the latest event
    const expectedValues1 = { ...depositData, depositId: intToU8Array32(1) }; // Verify the event props emitted match the depositData.
    for (let [key, value] of Object.entries(expectedValues1)) {
      if (key === "exclusivityParameter") key = "exclusivityDeadline"; // the prop and the event names differ on this key.
      assertSE(event[key], value, `${key} should match`);
    }

    // Test the id recovery with the conversion utils
    assertSE(u8Array32ToInt(event.depositId), 1, `depositId should recover to 1`);
    assertSE(u8Array32ToBigNumber(event.depositId), BigNumber.from(1), `depositId should recover to 1`);

    // Execute the second deposit call
    const tx2 = await approvedDeposit(depositData);
    events = await readEventsUntilFound(connection, tx2, [program]);
    event = events[0].data; // 0th event is the latest event.

    const expectedValues2 = { ...expectedValues1, depositId: intToU8Array32(2) }; // Verify the event props emitted match the depositData.
    for (let [key, value] of Object.entries(expectedValues2)) {
      if (key === "exclusivityParameter") key = "exclusivityDeadline"; // the prop and the event names differ on this key.
      assertSE(event[key], value, `${key} should match`);
    }

    // Test the id recovery with the conversion utils
    assertSE(u8Array32ToInt(event.depositId), 2, `depositId should recover to 2`);
    assertSE(u8Array32ToBigNumber(event.depositId), BigNumber.from(2), `depositId should recover to 2`);
  });

  it("Deposit with deadline before current time succeeds", async () => {
    const currentTime = await getCurrentTime(program, state);

    // Fill deadline is before current time on the contract
    let fillDeadline = currentTime - 1; // 1 second before current time on the contract.
    depositData.fillDeadline = new BN(fillDeadline);
    depositData.quoteTimestamp = new BN(currentTime - 1); // 1 second before current time on the contract to reset.

    const tx = await approvedDeposit(depositData);

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // 0th event is the latest event.

    assertSE(event.fillDeadline, fillDeadline, "Fill deadline should match");
  });

  it("Fails to process deposit when deposits are paused", async () => {
    // Pause deposits
    const pauseDepositsAccounts = { state, signer: owner, program: program.programId };
    await program.methods.pauseDeposits(true).accounts(pauseDepositsAccounts).rpc();
    const stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedDeposits, "Deposits should be paused");

    // Try to deposit. This should fail because deposits are paused.
    try {
      await approvedDeposit(depositData);
      assert.fail("Should not be able to process deposit when deposits are paused");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: DepositsArePaused", "Expected DepositsArePaused error");
    }
  });

  it("Fails to deposit tokens with InvalidQuoteTimestamp when quote timestamp is in the future", async () => {
    const currentTime = await getCurrentTime(program, state);
    const futureQuoteTimestamp = new BN(currentTime + 10); // 10 seconds in the future

    depositData.quoteTimestamp = futureQuoteTimestamp;

    try {
      await approvedDeposit(depositData);
      assert.fail("Deposit should have failed due to InvalidQuoteTimestamp");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: InvalidQuoteTimestamp", "Expected InvalidQuoteTimestamp error");
    }
  });

  it("Fails to deposit tokens with quoteTimestamp is too old", async () => {
    const currentTime = await getCurrentTime(program, state);
    const futureQuoteTimestamp = new BN(currentTime - depositQuoteTimeBuffer.toNumber() - 1); // older than buffer.

    depositData.quoteTimestamp = futureQuoteTimestamp;

    try {
      await approvedDeposit(depositData);
      assert.fail("Deposit should have failed due to InvalidQuoteTimestamp");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: InvalidQuoteTimestamp", "Expected InvalidQuoteTimestamp error");
    }
  });

  it("Fails to deposit tokens with InvalidFillDeadline when fill deadline is invalid", async () => {
    const currentTime = await getCurrentTime(program, state);

    // Fill deadline is too far ahead (longer than fill_deadline_buffer + currentTime)
    const invalidFillDeadline = currentTime + fillDeadlineBuffer.toNumber() + 1; // 1 seconds beyond the buffer
    depositData.fillDeadline = new BN(invalidFillDeadline);
    depositData.quoteTimestamp = new BN(currentTime);

    try {
      await approvedDeposit(depositData);
      assert.fail("Deposit should have failed due to InvalidFillDeadline (future deadline)");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidFillDeadline", "Expected InvalidFillDeadline error for future deadline");
    }
  });
  it("Fails to process deposit for mint inconsistent input_token", async () => {
    // Save the correct data from global scope before changing it when creating a new input token.
    const firstInputToken = inputToken;

    // Create a new input token and the vault.
    await setupInputToken();
    await createVault();

    // Try to execute the deposit call with malformed inputs where the first input token is passed combined with mint,
    // vault and user token account from the second input token.
    const malformedDepositData = { ...depositData, inputToken: firstInputToken };
    const malformedDepositAccounts = { ...depositAccounts };
    try {
      await approvedDeposit(malformedDepositData, malformedDepositAccounts);
      assert.fail("Should not be able to process deposit for inconsistent mint");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: InvalidMint", "Expected InvalidMint error");
    }
  });

  it("depositNow behaves as deposit but forces the quote timestamp as expected", async () => {
    // Set up initial deposit data. Note that this method has a slightly different interface to deposit, using
    // fillDeadlineOffset rather than fillDeadline. current chain time is added to fillDeadlineOffset to set the
    // fillDeadline for the deposit. exclusivityPeriod operates the same as in standard deposit.
    // Equally, depositNow does not have `quoteTimestamp`. this is set to the current time from the program.
    const fillDeadlineOffset = 60; // 60 seconds offset

    const depositNowData = {
      ...depositData,
      fillDeadlineOffset: new BN(fillDeadlineOffset),
      exclusivityPeriod: new BN(0),
    };

    const delegatePda = getDepositNowPda(depositNowData as DepositNowDataSeed, program.programId);
    // Delegate state PDA to pull depositor tokens.
    const approveIx = await createApproveCheckedInstruction(
      depositAccounts.depositorTokenAccount,
      depositAccounts.mint,
      delegatePda,
      depositor.publicKey,
      BigInt(depositData.inputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );

    // Execute the deposit_now call. Remove the quoteTimestamp from the depositData as not needed for this method.
    const depositIx = await program.methods
      .depositNow(
        depositNowData.depositor!,
        depositNowData.recipient!,
        depositNowData.inputToken!,
        depositNowData.outputToken!,
        depositNowData.inputAmount,
        depositNowData.outputAmount,
        depositNowData.destinationChainId,
        depositNowData.exclusiveRelayer!,
        fillDeadlineOffset,
        0,
        depositNowData.message
      )
      .accounts({ ...depositAccounts, delegate: delegatePda })
      .instruction();
    const depositTx = new Transaction().add(approveIx, depositIx);
    const tx = await sendAndConfirmTransaction(connection, depositTx, [payer, depositor]);

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // 0th event is the latest event.

    // Verify the event props emitted match the expected values
    const currentTime = await getCurrentTime(program, state);
    const expectedValues = {
      ...depositData,
      quoteTimestamp: currentTime,
      fillDeadline: currentTime + fillDeadlineOffset,
      depositId: intToU8Array32(1),
    };

    for (let [key, value] of Object.entries(expectedValues)) {
      if (key === "exclusivityParameter") key = "exclusivityDeadline"; // the prop and the event names differ on this key.
      assertSE(event[key], value, `${key} should match`);
    }
  });

  it("Fails with invalid exclusivity params", async () => {
    const currentTime = new BN(await getCurrentTime(program, state));
    depositData.quoteTimestamp = currentTime;
    // If exclusivityParameter is not zero, then exclusiveRelayer must be set.
    depositData.exclusiveRelayer = new PublicKey("11111111111111111111111111111111");
    depositData.exclusivityParameter = new BN(1);
    try {
      await approvedDeposit(depositData);
      assert.fail("Should have failed due to InvalidExclusiveRelayer");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidExclusiveRelayer");
    }

    // Test with other invalid exclusivityDeadline values
    const invalidExclusivityDeadlines = [
      maxExclusivityOffsetSeconds,
      maxExclusivityOffsetSeconds.add(new BN(1)),
      currentTime.sub(new BN(1)),
      currentTime.add(new BN(1)),
    ];

    for (const exclusivityDeadline of invalidExclusivityDeadlines) {
      depositData.exclusivityParameter = exclusivityDeadline;
      try {
        await approvedDeposit(depositData);
        assert.fail("Should have failed due to InvalidExclusiveRelayer");
      } catch (err: any) {
        assert.include(err.toString(), "InvalidExclusiveRelayer");
      }
    }

    // Test with exclusivityDeadline set to 0
    depositData.exclusivityParameter = new BN(0);
    await approvedDeposit(depositData);
  });

  it("Exclusivity param is used as an offset", async () => {
    const currentTime = new BN(await getCurrentTime(program, state));
    depositData.quoteTimestamp = currentTime;

    depositData.exclusiveRelayer = depositor.publicKey;
    depositData.exclusivityParameter = maxExclusivityOffsetSeconds;

    const tx = await approvedDeposit(depositData);

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // 0th event is the latest event
    assertSE(
      event.exclusivityDeadline,
      currentTime.add(maxExclusivityOffsetSeconds),
      "exclusivityDeadline should be current time + offset"
    );
  });

  it("Exclusivity param is used as a timestamp", async () => {
    const currentTime = new BN(await getCurrentTime(program, state));
    depositData.quoteTimestamp = currentTime;
    const exclusivityDeadlineTimestamp = maxExclusivityOffsetSeconds.add(new BN(1)); // 1 year + 1 second

    depositData.exclusiveRelayer = depositor.publicKey;
    depositData.exclusivityParameter = exclusivityDeadlineTimestamp;

    const tx = await approvedDeposit(depositData);

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // 0th event is the latest event;

    assertSE(event.exclusivityDeadline, exclusivityDeadlineTimestamp, "exclusivityDeadline should be passed in time");
  });

  it("Exclusivity param is set to 0", async () => {
    const currentTime = new BN(await getCurrentTime(program, state));
    depositData.quoteTimestamp = currentTime;
    const zeroExclusivity = new BN(0);

    depositData.exclusiveRelayer = depositor.publicKey;
    depositData.exclusivityParameter = zeroExclusivity;

    const tx = await approvedDeposit(depositData);

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // 0th event is the latest event;

    assertSE(event.exclusivityDeadline, zeroExclusivity, "Exclusivity deadline should always be 0");
  });
  it("unsafe deposit ID", async () => {
    const forcedDepositId = new BN(99);

    // Convert the inputs to byte arrays
    const msgSenderBytes = ethers.utils.arrayify(depositAccounts.signer.toBytes());
    const depositorBytes = ethers.utils.arrayify(depositData.depositor!.toBytes());
    const depositNonceBytes = ethers.utils.zeroPad(forcedDepositId.toArrayLike(Buffer, "le", 8), 8);

    const data = ethers.utils.concat([msgSenderBytes, depositorBytes, depositNonceBytes]); // Concatenate the byte arrays
    const expectedDepositId = ethers.utils.keccak256(data); // Hash the concatenated data using keccak256
    const expectedDepositIdArray = ethers.utils.arrayify(expectedDepositId);

    // Call the method to get the unsafe deposit ID
    const unsafeDepositIdTx = await program.methods
      .getUnsafeDepositId(depositAccounts.signer, depositData.depositor!, forcedDepositId)
      .view();

    assert.strictEqual(
      expectedDepositIdArray.toString(),
      unsafeDepositIdTx.toString(),
      "Deposit ID should match the expected hash"
    );

    // Delegate state PDA to pull depositor tokens.
    const approveIx = await createApproveCheckedInstruction(
      depositAccounts.depositorTokenAccount,
      depositAccounts.mint,
      getDepositPda(depositData as DepositDataSeed, program.programId),
      depositor.publicKey,
      BigInt(depositData.inputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );

    // Create the transaction for unsafeDeposit
    const unsafeDepositIx = await program.methods
      .unsafeDeposit(
        depositData.depositor!,
        depositData.recipient!,
        depositData.inputToken!,
        depositData.outputToken!,
        depositData.inputAmount!,
        depositData.outputAmount!,
        depositData.destinationChainId!,
        depositData.exclusiveRelayer!,
        forcedDepositId, // deposit nonce
        depositData.quoteTimestamp.toNumber(),
        depositData.fillDeadline.toNumber(),
        depositData.exclusivityParameter.toNumber(),
        depositData.message!
      )
      .accounts(depositAccounts) // Assuming depositAccounts is already set up correctly
      .instruction();

    const unsafeDepositTx = new Transaction().add(approveIx, unsafeDepositIx);
    const tx = await sendAndConfirmTransaction(connection, unsafeDepositTx, [payer, depositor]);

    // Wait for a short period to ensure the event is emitted

    // Read and verify the event
    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // Assuming the latest event is the one we want

    const expectedValues = { ...depositData, depositId: expectedDepositIdArray };

    for (let [key, value] of Object.entries(expectedValues)) {
      if (key === "exclusivityParameter") key = "exclusivityDeadline"; // Adjust for any key differences
      assertSE(event[key], value, `${key} should match`);
    }
  });

  it("Deposit with enabled CPI-guard", async () => {
    // CPI-guard is available only for the 2022 token program.
    tokenProgram = TOKEN_2022_PROGRAM_ID;
    await setupInputToken();
    await createVault();

    // Enable CPI-guard for the depositor (requires TA reallocation).
    const enableCpiGuardTx = new Transaction().add(
      createReallocateInstruction(depositorTA, payer.publicKey, [ExtensionType.CpiGuard], depositor.publicKey),
      createEnableCpiGuardInstruction(depositorTA, depositor.publicKey)
    );
    await sendAndConfirmTransaction(connection, enableCpiGuardTx, [payer, depositor]);

    // Verify vault balance is zero before the deposit
    let vaultAccount = await getAccount(connection, vault, undefined, tokenProgram);
    assertSE(vaultAccount.amount, "0", "Vault balance should be zero before the deposit");

    // Execute the deposit call
    await approvedDeposit(depositData);

    // Verify tokens leave the depositor's account
    const depositorAccount = await getAccount(connection, depositorTA, undefined, tokenProgram);
    assertSE(
      depositorAccount.amount,
      seedBalance - depositData.inputAmount.toNumber(),
      "Depositor's balance should be reduced by the deposited amount"
    );

    // Verify tokens are credited into the vault
    vaultAccount = await getAccount(connection, vault, undefined, tokenProgram);
    assertSE(vaultAccount.amount, depositData.inputAmount, "Vault balance should be increased by the deposited amount");
  });

  it("Deposit without approval fails", async () => {
    const depositDataValues = Object.values(depositData) as DepositDataValues;

    try {
      await program.methods
        .deposit(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed due to missing approval");
    } catch (err: any) {
      assert.include(err.toString(), "owner does not match");
    }
  });

  it("Deposit native token, new token account", async () => {
    // Fund depositor account with SOL.
    const nativeAmount = 1_000_000_000; // 1 SOL
    await connection.requestAirdrop(depositor.publicKey, nativeAmount * 2); // Add buffer for transaction fees.

    // Setup wSOL as the input token.
    inputToken = NATIVE_MINT;
    const nativeDecimals = 9;
    depositorTA = getAssociatedTokenAddressSync(inputToken, depositor.publicKey);
    await createVault();

    // Will need to add rent exemption to the deposit amount, will recover it at the end of the transaction.
    const rentExempt = await getMinimumBalanceForRentExemptAccount(connection);
    const transferIx = SystemProgram.transfer({
      fromPubkey: depositor.publicKey,
      toPubkey: depositorTA,
      lamports: BigInt(nativeAmount) + BigInt(rentExempt),
    });

    // Create wSOL user account.
    const createIx = createAssociatedTokenAccountIdempotentInstruction(
      depositor.publicKey,
      depositorTA,
      depositor.publicKey,
      inputToken
    );

    const nativeDepositData = {
      ...depositData,
      inputAmount: new BN(nativeAmount),
      outputAmount: intToU8Array32(nativeAmount),
    };
    const depositDataValues = Object.values(nativeDepositData) as DepositDataValues;
    const delegate = getDepositPda(nativeDepositData as DepositDataSeed, program.programId);
    const approveIx = await createApproveCheckedInstruction(
      depositAccounts.depositorTokenAccount,
      depositAccounts.mint,
      delegate,
      depositor.publicKey,
      BigInt(nativeAmount),
      nativeDecimals,
      undefined,
      tokenProgram
    );

    const depositIx = await program.methods
      .deposit(...depositDataValues)
      .accounts({ ...depositAccounts, delegate })
      .instruction();

    const closeIx = createCloseAccountInstruction(depositorTA, depositor.publicKey, depositor.publicKey);

    const iVaultAmount = (await getAccount(connection, vault, undefined, tokenProgram)).amount;

    const depositTx = new Transaction().add(transferIx, createIx, approveIx, depositIx, closeIx);
    const tx = await sendAndConfirmTransaction(connection, depositTx, [depositor]);

    const fVaultAmount = (await getAccount(connection, vault, undefined, tokenProgram)).amount;
    assertSE(
      fVaultAmount,
      iVaultAmount + BigInt(nativeAmount),
      "Vault balance should be increased by the deposited amount"
    );
  });

  it("Deposit native token, existing token account", async () => {
    // Fund depositor account with SOL.
    const nativeAmount = 1_000_000_000; // 1 SOL
    await connection.requestAirdrop(depositor.publicKey, nativeAmount * 2); // Add buffer for transaction fees.

    // Setup wSOL as the input token, creating the associated token account for the user.
    inputToken = NATIVE_MINT;
    const nativeDecimals = 9;
    depositorTA = (await getOrCreateAssociatedTokenAccount(connection, payer, inputToken, depositor.publicKey)).address;
    await createVault();

    // Transfer SOL to the user token account.
    const transferIx = SystemProgram.transfer({
      fromPubkey: depositor.publicKey,
      toPubkey: depositorTA,
      lamports: nativeAmount,
    });

    // Sync the user token account with the native balance.
    const syncIx = createSyncNativeInstruction(depositorTA);

    const nativeDepositData = {
      ...depositData,
      inputAmount: new BN(nativeAmount),
      outputAmount: intToU8Array32(nativeAmount),
    };
    const depositDataValues = Object.values(nativeDepositData) as DepositDataValues;
    const delegate = getDepositPda(nativeDepositData as DepositDataSeed, program.programId);
    const approveIx = await createApproveCheckedInstruction(
      depositAccounts.depositorTokenAccount,
      depositAccounts.mint,
      delegate,
      depositor.publicKey,
      BigInt(nativeAmount),
      nativeDecimals,
      undefined,
      tokenProgram
    );

    const depositIx = await program.methods
      .deposit(...depositDataValues)
      .accounts({ ...depositAccounts, delegate })
      .instruction();

    const iVaultAmount = (await getAccount(connection, vault, undefined, tokenProgram)).amount;

    const depositTx = new Transaction().add(transferIx, syncIx, approveIx, depositIx);
    const tx = await sendAndConfirmTransaction(connection, depositTx, [depositor]);

    const fVaultAmount = (await getAccount(connection, vault, undefined, tokenProgram)).amount;
    assertSE(
      fVaultAmount,
      iVaultAmount + BigInt(nativeAmount),
      "Vault balance should be increased by the deposited amount"
    );
  });

  it("Deposits tokens to a new vault", async () => {
    // Create new input token without creating a new vault for it.
    await setupInputToken();
    const inputTokenAccount = await provider.connection.getAccountInfo(inputToken);
    if (inputTokenAccount === null) throw new Error("Input mint account not found");
    vault = getAssociatedTokenAddressSync(
      inputToken,
      state,
      true,
      inputTokenAccount.owner,
      ASSOCIATED_TOKEN_PROGRAM_ID
    );

    // Update global variables using the new input token.
    depositData.inputToken = inputToken;
    depositAccounts.depositorTokenAccount = depositorTA;
    depositAccounts.vault = vault;
    depositAccounts.mint = inputToken;

    // Verify there is no vault account before the deposit.
    assert.isNull(await provider.connection.getAccountInfo(vault), "Vault should not exist before the deposit");

    // Execute the deposit call
    await approvedDeposit(depositData);

    // Verify tokens leave the depositor's account
    const depositorAccount = await getAccount(connection, depositorTA);
    assertSE(
      depositorAccount.amount,
      seedBalance - depositData.inputAmount.toNumber(),
      "Depositor's balance should be reduced by the deposited amount"
    );

    // Verify tokens are credited into the new vault
    const vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, depositData.inputAmount, "Vault balance should equal the deposited amount");
  });

  it("Output token cannot be zero address", async () => {
    const invalidDepositData = { ...depositData, outputToken: new PublicKey("11111111111111111111111111111111") };

    try {
      await approvedDeposit(invalidDepositData);
      assert.fail("Should not be able to process deposit with zero output token address");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: InvalidOutputToken", "Expected InvalidOutputToken error");
    }
  });

  describe("codama client and solana kit", () => {
    it("Deposit with with solana kit and codama client", async () => {
      // typescript is not happy with the depositData object
      if (!depositData.inputToken || !depositData.depositor) {
        throw new Error("Input token or depositor is null");
      }

      const rpcClient = createDefaultSolanaClient();
      const signer = await createSignerFromKeyPair(await createKeyPairFromBytes(depositor.secretKey));

      await airdropFactory(rpcClient)({
        recipientAddress: signer.address,
        lamports: lamports(100000000000000n),
        commitment: "confirmed",
      });

      const [eventAuthority] = await getProgramDerivedAddress({
        programAddress: address(program.programId.toString()),
        seeds: ["__event_authority"],
      });

      // note that we are using getApproveCheckedInstruction from @solana-program/token
      const approveIx = getApproveCheckedInstruction({
        source: address(depositAccounts.depositorTokenAccount.toString()),
        mint: address(depositAccounts.mint.toString()),
        delegate: address(getDepositPda(depositData as DepositDataSeed, program.programId).toString()),
        owner: address(depositor.publicKey.toString()),
        amount: BigInt(depositData.inputAmount.toString()),
        decimals: tokenDecimals,
      });

      const formattedDepositData = {
        depositor: address(depositData.depositor.toString()),
        recipient: address(depositData.recipient.toString()),
        inputToken: address(depositData.inputToken.toString()),
        outputToken: address(depositData.outputToken.toString()),
        inputAmount: BigInt(depositData.inputAmount.toString()),
        outputAmount: new Uint8Array(depositData.outputAmount),
        destinationChainId: depositData.destinationChainId.toNumber(),
        exclusiveRelayer: address(depositData.exclusiveRelayer.toString()),
        quoteTimestamp: depositData.quoteTimestamp.toNumber(),
        fillDeadline: depositData.fillDeadline.toNumber(),
        exclusivityParameter: depositData.exclusivityParameter.toNumber(),
        message: depositData.message,
      };

      const formattedAccounts = {
        state: address(depositAccounts.state.toString()),
        delegate: address(getDepositPda(depositData as DepositDataSeed, program.programId).toString()),
        depositorTokenAccount: address(depositAccounts.depositorTokenAccount.toString()),
        mint: address(depositAccounts.mint.toString()),
        tokenProgram: address(tokenProgram.toString()),
        program: address(program.programId.toString()),
        vault: address(vault.toString()),
      };

      const depositInput: DepositInput = {
        ...formattedDepositData,
        ...formattedAccounts,
        eventAuthority,
        signer,
      };

      const depositIx = await SvmSpokeClient.getDepositInstructionAsync(depositInput);

      const tx = await pipe(
        await createDefaultTransaction(rpcClient, signer),
        (tx) => appendTransactionMessageInstruction(approveIx, tx),
        (tx) => appendTransactionMessageInstruction(depositIx, tx),
        (tx) => signAndSendTransaction(rpcClient, tx)
      );

      const events = await readEventsUntilFound(connection, tx, [program]);
      const event = events[0].data; // 0th event is the latest event;
      assertSE(event.depositId, intToU8Array32(1), "Deposit ID should match the expected hash");
    });
  });
});
