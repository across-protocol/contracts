import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import { BigNumber, ethers } from "ethers";
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
import { common } from "./SvmSpoke.common";
import { DepositDataValues } from "../../src/types/svm";
import { intToU8Array32, readEventsUntilFound, u8Array32ToInt, u8Array32ToBigNumber } from "../../src/svm/web3-v1";
import { MAX_EXCLUSIVITY_OFFSET_SECONDS } from "../../test-utils";
const { provider, connection, program, owner, seedBalance, initializeState, depositData } = common;
const { createRoutePda, getVaultAta, assertSE, assert, getCurrentTime, depositQuoteTimeBuffer, fillDeadlineBuffer } =
  common;

const maxExclusivityOffsetSeconds = new BN(MAX_EXCLUSIVITY_OFFSET_SECONDS); // 1 year in seconds

describe("svm_spoke.deposit", () => {
  anchor.setProvider(provider);

  const depositor = Keypair.generate();
  const payer = (anchor.AnchorProvider.env().wallet as anchor.Wallet).payer;
  const tokenDecimals = 6;

  let state: PublicKey, inputToken: PublicKey, depositorTA: PublicKey, vault: PublicKey, tokenProgram: PublicKey;
  let seed: BN;

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
    const route = createRoutePda(inputToken, seed, routeChainId);
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
    const tx = await sendAndConfirmTransaction(connection, depositTx, [payer, depositor]);
    return tx;
  };

  beforeEach(async () => {
    ({ state, seed } = await initializeState());

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
    const tx = await approvedDepositV3(depositDataValues);

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

    // Execute the second deposit_v3 call
    const tx2 = await approvedDepositV3(depositDataValues);
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

    const depositDataValues = Object.values(depositData) as DepositDataValues;
    const tx = await approvedDepositV3(depositDataValues);

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events[0].data; // 0th event is the latest event.

    assertSE(event.fillDeadline, fillDeadline, "Fill deadline should match");
  });

  it("Fails to deposit tokens to a route that is uninitalized", async () => {
    const differentChainId = new BN(2); // Different chain ID
    if (!depositData.inputToken) {
      throw new Error("Input token is null");
    }
    const differentRoutePda = createRoutePda(depositData.inputToken, seed, differentChainId);
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

    // Fill deadline is too far ahead (longer than fill_deadline_buffer + currentTime)
    const invalidFillDeadline = currentTime + fillDeadlineBuffer.toNumber() + 1; // 1 seconds beyond the buffer
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
    const fakeVault = await getVaultAta(inputToken, fakeState.state);

    const fakeRouteChainId = new BN(3);
    const fakeRoutePda = createRoutePda(inputToken, fakeState.seed, fakeRouteChainId);

    // A seeds constraint was violated.
    const fakeSetEnableRouteAccounts = {
      signer: owner,
      payer: owner,
      state: fakeState.state,
      route: fakeRoutePda,
      vault: fakeVault,
      originTokenMint: inputToken,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
      program: program.programId,
    };

    await program.methods.setEnableRoute(inputToken, fakeRouteChainId, true).accounts(fakeSetEnableRouteAccounts).rpc();

    const fakeDepositAccounts = {
      state: fakeState.state,
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
    const tx = await approvedDepositV3(depositDataValues, fakeDepositAccounts);

    let events = await readEventsUntilFound(connection, tx, [program]);
    let event = events[0].data; // 0th event is the latest event.
    const expectedValues = {
      ...{ ...depositData, destinationChainId: fakeRouteChainId },
      depositId: intToU8Array32(1),
    }; // Verify the event props emitted match the depositData.
    for (let [key, value] of Object.entries(expectedValues)) {
      if (key === "exclusivityParameter") key = "exclusivityDeadline"; // the prop and the event names differ on this key.
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
        0,
        depositData.message
      )
      .accounts(depositAccounts)
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
      const depositDataValues = Object.values(depositData) as DepositDataValues;
      await approvedDepositV3(depositDataValues);
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
        const depositDataValues = Object.values(depositData) as DepositDataValues;
        await approvedDepositV3(depositDataValues);
        assert.fail("Should have failed due to InvalidExclusiveRelayer");
      } catch (err: any) {
        assert.include(err.toString(), "InvalidExclusiveRelayer");
      }
    }

    // Test with exclusivityDeadline set to 0
    depositData.exclusivityParameter = new BN(0);
    const depositDataValues = Object.values(depositData) as DepositDataValues;
    await approvedDepositV3(depositDataValues);
  });

  it("Exclusivity param is used as an offset", async () => {
    const currentTime = new BN(await getCurrentTime(program, state));
    depositData.quoteTimestamp = currentTime;

    depositData.exclusiveRelayer = depositor.publicKey;
    depositData.exclusivityParameter = maxExclusivityOffsetSeconds;

    const depositDataValues = Object.values(depositData) as DepositDataValues;
    const tx = await approvedDepositV3(depositDataValues);

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

    const depositDataValues = Object.values(depositData) as DepositDataValues;
    const tx = await approvedDepositV3(depositDataValues);

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

    const depositDataValues = Object.values(depositData) as DepositDataValues;
    const tx = await approvedDepositV3(depositDataValues);

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
      depositAccounts.state,
      depositor.publicKey,
      BigInt(depositData.inputAmount.toString()),
      tokenDecimals,
      undefined,
      tokenProgram
    );

    // Create the transaction for unsafeDepositV3
    const unsafeDepositIx = await program.methods
      .unsafeDepositV3(
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
