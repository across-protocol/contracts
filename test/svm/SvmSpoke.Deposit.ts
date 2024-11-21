import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import {
  ASSOCIATED_TOKEN_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  TOKEN_2022_PROGRAM_ID,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
  getAccount,
  createApproveCheckedInstruction,
  createEnableCpiGuardInstruction,
  createReallocateInstruction,
  ExtensionType,
} from "@solana/spl-token";
import { PublicKey, Keypair, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { common, DepositDataValues } from "./SvmSpoke.common";
import { readProgramEvents } from "./utils";
const { provider, connection, program, owner, seedBalance, initializeState, depositData } = common;
const { createRoutePda, getVaultAta, assertSE, assert, getCurrentTime, depositQuoteTimeBuffer, fillDeadlineBuffer } =
  common;

describe("svm_spoke.deposit", () => {
  anchor.setProvider(provider);

  const depositor = Keypair.generate();
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const tokenDecimals = 6;

  let state: PublicKey, inputToken: PublicKey, depositorTA: PublicKey, vault: PublicKey, tokenProgram: PublicKey;

  // Re-used between tests to simplify props.
  type DepositAccounts = {
    state: PublicKey;
    route: PublicKey;
    signer: PublicKey;
    depositorTokenAccount: PublicKey;
    vault: PublicKey;
    mint: PublicKey;
    tokenProgram: PublicKey;
    program: PublicKey;
  };
  let depositAccounts: DepositAccounts;

  let setEnableRouteAccounts: any; // Common variable for setEnableRoute accounts

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

  const enableRoute = async () => {
    const routeChainId = new BN(1);
    const route = createRoutePda(inputToken, state, routeChainId);
    vault = await getVaultAta(inputToken, state);

    setEnableRouteAccounts = {
      signer: owner,
      payer: owner,
      state,
      route,
      vault,
      originTokenMint: inputToken, // Note the Sol expects this to be named originTokenMint.
      tokenProgram: tokenProgram ?? TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };

    await program.methods.setEnableRoute(inputToken, routeChainId, true).accounts(setEnableRouteAccounts).rpc();

    // Set known fields in the depositData.
    depositData.depositor = depositor.publicKey;
    depositData.inputToken = inputToken;

    depositAccounts = {
      state,
      route,
      signer: depositor.publicKey,
      depositorTokenAccount: depositorTA,
      vault,
      mint: inputToken,
      tokenProgram: tokenProgram ?? TOKEN_PROGRAM_ID,
      program: program.programId,
    };
  };

  const approvedDepositV3 = async (
    depositDataValues: DepositDataValues,
    calledDepositAccounts: DepositAccounts = depositAccounts
  ) => {
    // Delegate state PDA to pull depositor tokens.
    const approveIx = await createApproveCheckedInstruction(
      calledDepositAccounts.depositorTokenAccount,
      calledDepositAccounts.mint,
      calledDepositAccounts.state,
      depositor.publicKey,
      BigInt(depositData.inputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );
    const depositIx = await program.methods
      .depositV3(...depositDataValues)
      .accounts(calledDepositAccounts)
      .instruction();
    const depositTx = new Transaction().add(approveIx, depositIx);
    await sendAndConfirmTransaction(connection, depositTx, [payer, depositor]);
  };

  beforeEach(async () => {
    state = await initializeState();

    tokenProgram = TOKEN_PROGRAM_ID; // Some tests might override this.
    await setupInputToken();

    await enableRoute();
  });
  it("Deposits tokens via deposit_v3 function and checks balances", async () => {
    // Verify vault balance is zero before the deposit
    let vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, "0", "Vault balance should be zero before the deposit");

    // Execute the deposit_v3 call
    let depositDataValues = Object.values(depositData) as DepositDataValues;
    await approvedDepositV3(depositDataValues);

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

    // Execute the second deposit_v3 call

    depositDataValues = Object.values({ ...depositData, inputAmount: secondInputAmount }) as DepositDataValues;
    await approvedDepositV3(depositDataValues);

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

  it("Verifies V3FundsDeposited after deposits", async () => {
    depositData.inputAmount = depositData.inputAmount.add(new BN(69));

    // Execute the first deposit_v3 call
    let depositDataValues = Object.values(depositData) as DepositDataValues;
    await approvedDepositV3(depositDataValues);
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent
    let events = await readProgramEvents(connection, program);
    let event = events.find((event) => event.name === "v3FundsDeposited").data;
    const currentTime = await getCurrentTime(program, state);
    const { exclusivityPeriod, ...restOfDepositData } = depositData; // Strip exclusivityPeriod from depositData
    const expectedValues1 = {
      ...restOfDepositData,
      depositId: "1",
      exclusivityDeadline: currentTime + exclusivityPeriod.toNumber(),
    }; // Verify the event props emitted match the depositData.
    for (const [key, value] of Object.entries(expectedValues1)) {
      assertSE(event[key], value, `${key} should match`);
    }

    // Execute the second deposit_v3 call
    await approvedDepositV3(depositDataValues);
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent for the second deposit
    events = await readProgramEvents(connection, program);
    event = events.find((event) => event.name === "v3FundsDeposited" && event.data.depositId.toString() === "2").data;

    const expectedValues2 = { ...expectedValues1, depositId: "2" }; // Verify the event props emitted match the depositData.
    for (const [key, value] of Object.entries(expectedValues2)) {
      assertSE(event[key], value, `${key} should match`);
    }
  });

  it("Fails to deposit tokens to a route that is uninitalized", async () => {
    const differentChainId = new BN(2); // Different chain ID
    if (!depositData.inputToken) {
      throw new Error("Input token is null");
    }
    const differentRoutePda = createRoutePda(depositData.inputToken, state, differentChainId);
    depositAccounts.route = differentRoutePda;

    try {
      const depositDataValues = Object.values({
        ...depositData,
        destinationChainId: differentChainId,
      }) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
      assert.fail("Deposit should have failed for a route that is not initialized");
    } catch (err: any) {
      assert.include(err.toString(), "AccountNotInitialized", "Expected AccountNotInitialized error");
    }
  });

  it("Fails to deposit tokens to a route that is explicitly disabled", async () => {
    // Disable the route
    await program.methods
      .setEnableRoute(depositData.inputToken!, depositData.destinationChainId, false)
      .accounts(setEnableRouteAccounts)
      .rpc();

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
      assert.fail("Deposit should have failed for a route that is explicitly disabled");
    } catch (err: any) {
      assert.include(err.toString(), "DisabledRoute", "Expected DisabledRoute error");
    }
  });

  it("Fails to process deposit when deposits are paused", async () => {
    // Pause deposits
    const pauseDepositsAccounts = { state, signer: owner, program: program.programId };
    await program.methods.pauseDeposits(true).accounts(pauseDepositsAccounts).rpc();
    const stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedDeposits, "Deposits should be paused");

    // Try to deposit. This should fail because deposits are paused.
    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
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
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
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
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
      assert.fail("Deposit should have failed due to InvalidQuoteTimestamp");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: InvalidQuoteTimestamp", "Expected InvalidQuoteTimestamp error");
    }
  });

  it("Fails to deposit tokens with InvalidFillDeadline when fill deadline is invalid", async () => {
    const currentTime = await getCurrentTime(program, state);

    // Case 1: Fill deadline is older than the current time on the contract
    let invalidFillDeadline = currentTime - 1; // 1 second before current time on the contract.
    depositData.fillDeadline = new BN(invalidFillDeadline);
    depositData.quoteTimestamp = new BN(currentTime - 1); // 1 second before current time on the contract to reset.

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
      assert.fail("Deposit should have failed due to InvalidFillDeadline (past deadline)");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidFillDeadline", "Expected InvalidFillDeadline error for past deadline");
    }

    // Case 2: Fill deadline is too far ahead (longer than fill_deadline_buffer + currentTime)
    invalidFillDeadline = currentTime + fillDeadlineBuffer.toNumber() + 1; // 1 seconds beyond the buffer
    depositData.fillDeadline = new BN(invalidFillDeadline);

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
      assert.fail("Deposit should have failed due to InvalidFillDeadline (future deadline)");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidFillDeadline", "Expected InvalidFillDeadline error for future deadline");
    }
  });
  it("Fails to process deposit for mint inconsistent input_token", async () => {
    // Save the correct data and accounts from global scope before changing it when creating a new input token.
    const firstInputToken = inputToken;
    const firstDepositAccounts = depositAccounts;

    // Create a new input token and enable the route (this updates global scope variables).
    await setupInputToken();
    await enableRoute();

    // Try to execute the deposit_v3 call with malformed inputs where the first input token and its derived route is
    // passed combined with mint, vault and user token account from the second input token.
    const malformedDepositData = { ...depositData, inputToken: firstInputToken };
    const malformedDepositAccounts = { ...depositAccounts, route: firstDepositAccounts.route };
    try {
      const depositDataValues = Object.values(malformedDepositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues, malformedDepositAccounts);
      assert.fail("Should not be able to process deposit for inconsistent mint");
    } catch (err: any) {
      assert.include(err.toString(), "Error Code: InvalidMint", "Expected InvalidMint error");
    }
  });

  it("Tests deposit with a fake route PDA", async () => {
    // Create fake program state
    const fakeState = await initializeState();
    const fakeVault = await getVaultAta(inputToken, fakeState);

    const fakeRouteChainId = new BN(3);
    const fakeRoutePda = createRoutePda(inputToken, fakeState, fakeRouteChainId);

    // A seeds constraint was violated.
    const fakeSetEnableRouteAccounts = {
      signer: owner,
      payer: owner,
      state: fakeState,
      route: fakeRoutePda,
      vault: fakeVault,
      originTokenMint: inputToken,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };

    await program.methods.setEnableRoute(inputToken, fakeRouteChainId, true).accounts(fakeSetEnableRouteAccounts).rpc();

    await new Promise((resolve) => setTimeout(resolve, 2000));

    const fakeDepositAccounts = {
      state: fakeState,
      route: fakeRoutePda,
      signer: depositor.publicKey,
      depositorTokenAccount: depositorTA,
      vault: fakeVault,
      mint: inputToken,
      tokenProgram: TOKEN_PROGRAM_ID,
      program: program.programId,
    };

    // Deposit with the fake state and route PDA should succeed.
    const depositDataValues = Object.values({
      ...depositData,
      destinationChainId: fakeRouteChainId,
    }) as DepositDataValues;
    await approvedDepositV3(depositDataValues, fakeDepositAccounts);

    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent
    let events = await readProgramEvents(connection, program);
    let event = events.find((event) => event.name === "v3FundsDeposited").data;
    const { exclusivityPeriod, ...restOfDepositData } = depositData; // Strip exclusivityPeriod from depositData
    const expectedValues = { ...{ ...restOfDepositData, destinationChainId: fakeRouteChainId }, depositId: "1" }; // Verify the event props emitted match the depositData.
    for (const [key, value] of Object.entries(expectedValues)) {
      assertSE(event[key], value, `${key} should match`);
    }

    // Check fake vault acount balance
    const fakeVaultAccount = await getAccount(connection, fakeVault);
    assertSE(
      fakeVaultAccount.amount,
      depositData.inputAmount.toNumber(),
      "Fake vault balance should be increased by the deposited amount"
    );

    // Deposit with the fake route in the original program state should fail.
    try {
      const depositDataValues = Object.values({
        ...{ ...depositData, destinationChainId: fakeRouteChainId },
      }) as DepositDataValues;
      await approvedDepositV3(depositDataValues, { ...depositAccounts, route: fakeRoutePda });
      assert.fail("Deposit should have failed for a fake route PDA");
    } catch (err: any) {
      assert.include(err.toString(), "A seeds constraint was violated");
    }

    const vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, 0, "Vault balance should not be changed by the fake route deposit");
  });

  it("depositV3Now behaves as deposit but forces the quote timestamp as expected", async () => {
    // Set up initial deposit data. Note that this method has a slightly different interface to deposit, using
    // fillDeadlineOffset rather than fillDeadline. current chain time is added to fillDeadlineOffset to set the
    // fillDeadline for the deposit. exclusivityPeriod operates the same as in standard deposit.
    // Equally, depositV3Now does not have `quoteTimestamp`. this is set to the current time from the program.
    const fillDeadlineOffset = 60; // 60 seconds offset

    // Delegate state PDA to pull depositor tokens.
    const approveIx = await createApproveCheckedInstruction(
      depositAccounts.depositorTokenAccount,
      depositAccounts.mint,
      depositAccounts.state,
      depositor.publicKey,
      BigInt(depositData.inputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );

    // Execute the deposit_v3_now call. Remove the quoteTimestamp from the depositData as not needed for this method.
    const depositIx = await program.methods
      .depositV3Now(
        depositData.depositor!,
        depositData.recipient!,
        depositData.inputToken!,
        depositData.outputToken!,
        depositData.inputAmount,
        depositData.outputAmount,
        depositData.destinationChainId,
        depositData.exclusiveRelayer!,
        fillDeadlineOffset,
        depositData.exclusivityPeriod.toNumber(),
        depositData.message
      )
      .accounts(depositAccounts)
      .instruction();
    const depositTx = new Transaction().add(approveIx, depositIx);
    await sendAndConfirmTransaction(connection, depositTx, [payer, depositor]);

    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent
    const events = await readProgramEvents(connection, program);
    const event = events.find((event) => event.name === "v3FundsDeposited").data;

    // Verify the event props emitted match the expected values
    const currentTime = await getCurrentTime(program, state);
    const { exclusivityPeriod, ...restOfDepositData } = depositData; // Strip exclusivityPeriod from depositData
    const expectedValues = {
      ...restOfDepositData,
      quoteTimestamp: currentTime,
      fillDeadline: currentTime + fillDeadlineOffset,
      exclusivityDeadline: currentTime + exclusivityPeriod.toNumber(),
      depositId: "1",
    };

    for (const [key, value] of Object.entries(expectedValues)) {
      assertSE(event[key], value, `${key} should match`);
    }
  });

  it("Deposit with enabled CPI-guard", async () => {
    // CPI-guard is available only for the 2022 token program.
    tokenProgram = TOKEN_2022_PROGRAM_ID;
    await setupInputToken();
    await enableRoute();

    // Enable CPI-guard for the depositor (requires TA reallocation).
    const enableCpiGuardTx = new Transaction().add(
      createReallocateInstruction(depositorTA, payer.publicKey, [ExtensionType.CpiGuard], depositor.publicKey),
      createEnableCpiGuardInstruction(depositorTA, depositor.publicKey)
    );
    await sendAndConfirmTransaction(connection, enableCpiGuardTx, [payer, depositor]);

    // Verify vault balance is zero before the deposit
    let vaultAccount = await getAccount(connection, vault, undefined, tokenProgram);
    assertSE(vaultAccount.amount, "0", "Vault balance should be zero before the deposit");

    // Execute the deposit_v3 call
    const depositDataValues = Object.values(depositData) as DepositDataValues;
    await approvedDepositV3(depositDataValues);

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
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed due to missing approval");
    } catch (err: any) {
      assert.include(err.toString(), "owner does not match");
    }
  });
});
