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
import { common, DepositDataValues } from "./SvmSpoke.common";
import { readProgramEvents } from "./utils";
const { provider, connection, program, owner, seedBalance, initializeState, depositData } = common;
const { createRoutePda, getVaultAta, assertSE, assert, getCurrentTime, depositQuoteTimeBuffer, fillDeadlineBuffer } =
  common;

describe("svm_spoke.deposit", () => {
  anchor.setProvider(provider);

  const depositor = Keypair.generate();
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  let state: PublicKey, inputToken: PublicKey, depositorTA: PublicKey, vault: PublicKey;
  let depositAccounts: any; // Re-used between tests to simplify props.
  let setEnableRouteAccounts: any; // Common variable for setEnableRoute accounts

  const setupInputToken = async () => {
    inputToken = await createMint(connection, payer, owner, owner, 6);

    depositorTA = (await getOrCreateAssociatedTokenAccount(connection, payer, inputToken, depositor.publicKey)).address;
    await mintTo(connection, payer, inputToken, depositorTA, owner, seedBalance);
  };

  const enableRoute = async () => {
    const routeChainId = new BN(1);
    const route = createRoutePda(inputToken, state, routeChainId);
    vault = getVaultAta(inputToken, state);

    setEnableRouteAccounts = {
      signer: owner,
      payer: owner,
      state,
      route,
      vault,
      originTokenMint: inputToken, // Note the Sol expects this to be named originTokenMint.
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };

    await program.methods
      .setEnableRoute(Array.from(inputToken.toBuffer()), routeChainId, true)
      .accounts(setEnableRouteAccounts)
      .rpc();

    // Set known fields in the depositData.
    depositData.depositor = depositor.publicKey;
    depositData.inputToken = inputToken;

    depositAccounts = {
      state,
      route,
      signer: depositor.publicKey,
      userTokenAccount: depositorTA,
      vault,
      mint: inputToken,
      tokenProgram: TOKEN_PROGRAM_ID,
    };
  };

  before("Creates token mint and associated token accounts", async () => {
    await setupInputToken();
  });

  beforeEach(async () => {
    state = await initializeState();

    await enableRoute();
  });

  it("Deposits tokens via deposit_v3 function and checks balances", async () => {
    // Verify vault balance is zero before the deposit
    let vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, "0", "Vault balance should be zero before the deposit");

    // Execute the deposit_v3 call
    let depositDataValues = Object.values(depositData) as DepositDataValues;
    await program.methods
      .depositV3(...depositDataValues)
      .accounts(depositAccounts)
      .signers([depositor])
      .rpc();

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
    await program.methods
      .depositV3(...depositDataValues)
      .accounts(depositAccounts)
      .signers([depositor])
      .rpc();

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
    await program.methods
      .depositV3(...depositDataValues)
      .accounts(depositAccounts)
      .signers([depositor])
      .rpc();
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent
    let events = await readProgramEvents(connection, program);
    let event = events.find((event) => event.name === "v3FundsDeposited").data;
    const expectedValues1 = { ...depositData, depositId: "1" }; // Verify the event props emitted match the depositData.
    for (const [key, value] of Object.entries(expectedValues1)) {
      assertSE(event[key], value, `${key} should match`);
    }

    // Execute the second deposit_v3 call
    await program.methods
      .depositV3(...depositDataValues)
      .accounts(depositAccounts)
      .signers([depositor])
      .rpc();
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent for the second deposit
    events = await readProgramEvents(connection, program);
    event = events.find((event) => event.name === "v3FundsDeposited" && event.data.depositId.toString() === "2").data;

    const expectedValues2 = { ...depositData, depositId: "2" }; // Verify the event props emitted match the depositData.
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
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed for a route that is not initialized");
    } catch (err: any) {
      assert.include(err.toString(), "AccountNotInitialized", "Expected AccountNotInitialized error");
    }
  });

  it("Fails to deposit tokens to a route that is explicitly disabled", async () => {
    // Disable the route
    await program.methods
      .setEnableRoute(Array.from(depositData.inputToken!.toBuffer()), depositData.destinationChainId, false)
      .accounts(setEnableRouteAccounts)
      .rpc();

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
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
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Should not be able to process deposit when deposits are paused");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "DepositsArePaused", "Expected error code DepositsArePaused");
    }
  });

  it("Fails to deposit tokens with InvalidQuoteTimestamp when quote timestamp is in the future", async () => {
    const currentTime = await getCurrentTime(program, state);
    const futureQuoteTimestamp = new BN(currentTime + 10); // 10 seconds in the future

    depositData.quoteTimestamp = futureQuoteTimestamp;

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed due to InvalidQuoteTimestamp");
    } catch (err: any) {
      assert.include(
        err.toString(),
        "attempt to subtract with overflow",
        "Expected underflow error due to future quote timestamp"
      );
    }
  });

  it("Fails to deposit tokens with quoteTimestamp is too old", async () => {
    const currentTime = await getCurrentTime(program, state);
    const futureQuoteTimestamp = new BN(currentTime - depositQuoteTimeBuffer.toNumber() - 1); // older than buffer.

    depositData.quoteTimestamp = futureQuoteTimestamp;

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
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
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed due to InvalidFillDeadline (past deadline)");
    } catch (err: any) {
      assert.include(err.toString(), "InvalidFillDeadline", "Expected InvalidFillDeadline error for past deadline");
    }

    // Case 2: Fill deadline is too far ahead (longer than fill_deadline_buffer + currentTime)
    invalidFillDeadline = currentTime + fillDeadlineBuffer.toNumber() + 1; // 1 seconds beyond the buffer
    depositData.fillDeadline = new BN(invalidFillDeadline);

    try {
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
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
      await program.methods
        .depositV3(...depositDataValues)
        .accounts(malformedDepositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Should not be able to process deposit for inconsistent mint");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "InvalidMint", "Expected error code InvalidMint");
    }
  });

  it("Tests deposit with a fake route PDA", async () => {
    // Create fake program state
    const fakeState = await initializeState();
    const fakeVault = getVaultAta(inputToken, fakeState);

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

    await program.methods
      .setEnableRoute(Array.from(inputToken.toBuffer()), fakeRouteChainId, true)
      .accounts(fakeSetEnableRouteAccounts)
      .rpc();

    await new Promise((resolve) => setTimeout(resolve, 2000));

    const fakeDepositAccounts = {
      state: fakeState,
      route: fakeRoutePda,
      signer: depositor.publicKey,
      userTokenAccount: depositorTA,
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
    await program.methods
      .depositV3(...depositDataValues)
      .accounts(fakeDepositAccounts)
      .signers([depositor])
      .rpc();

    await new Promise((resolve) => setTimeout(resolve, 500));

    // Fetch and verify the depositEvent
    let events = await readProgramEvents(connection, program);
    let event = events.find((event) => event.name === "v3FundsDeposited").data;
    const expectedValues1 = { ...{ ...depositData, destinationChainId: fakeRouteChainId }, depositId: "1" }; // Verify the event props emitted match the depositData.
    for (const [key, value] of Object.entries(expectedValues1)) {
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
      await program.methods
        .depositV3(...depositDataValues)
        .accounts({ ...depositAccounts, route: fakeRoutePda })
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed for a fake route PDA");
    } catch (err: any) {
      assert.include(err.toString(), "A seeds constraint was violated");
    }

    const vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, 0, "Vault balance should not be changed by the fake route deposit");
  });
});
