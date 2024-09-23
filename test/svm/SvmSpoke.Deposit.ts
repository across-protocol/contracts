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
import { readProgramEvents } from "../../src/SvmUtils";
import { common } from "./SvmSpoke.common";
const { provider, connection, program, owner, seedBalance, initializeState, depositData } = common;
const { createRoutePda, getVaultAta, assertSE, assert } = common;

describe("svm_spoke.deposit", () => {
  anchor.setProvider(provider);

  const depositor = Keypair.generate();
  const payer = anchor.AnchorProvider.env().wallet.payer;
  let state: PublicKey, inputToken: PublicKey, depositorTA: PublicKey, vault: PublicKey;
  let depositAccounts: any; // Re-used between tests to simplify props.
  let setEnableRouteAccounts: any; // Common variable for setEnableRoute accounts

  before("Creates token mint and associated token accounts", async () => {
    inputToken = await createMint(connection, payer, owner, owner, 6);

    depositorTA = (await getOrCreateAssociatedTokenAccount(connection, payer, inputToken, depositor.publicKey)).address;
    await mintTo(connection, payer, inputToken, depositorTA, owner, seedBalance);
  });

  beforeEach(async () => {
    state = await initializeState();

    const routeChainId = new BN(1);
    const route = createRoutePda(inputToken, routeChainId);
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
      .setEnableRoute(inputToken.toBytes(), routeChainId, true)
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
  });

  it("Deposits tokens via deposit_v3 function and checks balances", async () => {
    // Verify vault balance is zero before the deposit
    let vaultAccount = await getAccount(connection, vault);
    assertSE(vaultAccount.amount, "0", "Vault balance should be zero before the deposit");

    // Execute the deposit_v3 call
    await program.methods
      .depositV3(...Object.values(depositData))
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
    await program.methods
      .depositV3(...Object.values({ ...depositData, inputAmount: secondInputAmount }))
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
    await program.methods
      .depositV3(...Object.values(depositData))
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
      .depositV3(...Object.values(depositData))
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
    const differentRoutePda = createRoutePda(depositData.inputToken, differentChainId);
    depositAccounts.route = differentRoutePda;

    try {
      await program.methods
        .depositV3(...Object.values({ ...depositData, destinationChainId: differentChainId }))
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed for a route that is not initialized");
    } catch (err) {
      assert.include(err.toString(), "AccountNotInitialized", "Expected AccountNotInitialized error");
    }
  });

  it("Fails to deposit tokens to a route that is explicitly disabled", async () => {
    // Disable the route
    await program.methods
      .setEnableRoute(depositData.inputToken.toBytes(), depositData.destinationChainId, false)
      .accounts(setEnableRouteAccounts)
      .rpc();

    try {
      await program.methods
        .depositV3(...Object.values(depositData))
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Deposit should have failed for a route that is explicitly disabled");
    } catch (err) {
      assert.include(err.toString(), "DisabledRoute", "Expected DisabledRoute error");
    }
  });

  it("Fails to process deposit when deposits are paused", async () => {
    // Pause deposits
    await program.methods.pauseDeposits(true).accounts({ state, signer: owner }).rpc();
    const stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedDeposits, "Deposits should be paused");

    // Try to deposit. This should fail because deposits are paused.
    try {
      await program.methods
        .depositV3(...Object.values(depositData))
        .accounts(depositAccounts)
        .signers([depositor])
        .rpc();
      assert.fail("Should not be able to process deposit when deposits are paused");
    } catch (err) {
      assert.instanceOf(err, anchor.AnchorError);
      assert.strictEqual(err.error.errorCode.code, "DepositsArePaused", "Expected error code DepositsArePaused");
    }
  });
  // TODO: test invalid Deposit deadline for InvalidQuoteTimestamp
  // TODO: test invalid InvalidFillDeadline
});
