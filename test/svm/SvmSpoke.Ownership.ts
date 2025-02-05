import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import { Keypair, PublicKey } from "@solana/web3.js";
import { assert } from "chai";
import { common } from "./SvmSpoke.common";
import { readEventsUntilFound } from "../../src/svm/web3-v1";

const { provider, program, owner, initializeState, crossDomainAdmin, assertSE } = common;

describe("svm_spoke.ownership", () => {
  anchor.setProvider(provider);

  const nonOwner = Keypair.generate();
  const newOwner = Keypair.generate();
  const newCrossDomainAdmin = Keypair.generate();
  let state: PublicKey;

  beforeEach(async () => {
    ({ state } = await initializeState());
  });

  it("Initializes state with provided initial state", async () => {
    const initialState = {
      initialNumberOfDeposits: new BN(5),
      chainId: new BN(420), // Set the chainId
      remoteDomain: new BN(11), // Set the remoteDomain
      crossDomainAdmin, // Use the existing crossDomainAdmin
      depositQuoteTimeBuffer: new BN(3600), // Set the depositQuoteTimeBuffer
      fillDeadlineBuffer: new BN(14400), // Set the fillDeadlineBuffer (4 hours)
    };

    // Initialize state with the provided initial state
    ({ state } = await initializeState(undefined, initialState));

    // Fetch the updated state
    const stateData = await program.account.state.fetch(state);

    // Assert other properties as needed
    Object.keys(initialState).forEach((key) => {
      const adjustedKey = key === "initialNumberOfDeposits" ? "numberOfDeposits" : key; // stored with diff key in state.
      assertSE(
        stateData[adjustedKey as keyof typeof stateData],
        initialState[key as keyof typeof initialState],
        `${key} should match`
      );
    });
  });

  it("Pauses and unpauses deposits", async () => {
    assert.isFalse((await program.account.state.fetch(state)).pausedDeposits, "Deposits should not be paused");

    // Pause deposits as owner
    const pauseDepositsAccounts = { state, signer: owner, program: program.programId };
    const tx = await program.methods.pauseDeposits(true).accounts(pauseDepositsAccounts).rpc();

    // Fetch the updated state
    let stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedDeposits, "Deposits should be paused");

    // Verify the PausedDeposits event
    let events = await readEventsUntilFound(provider.connection, tx, [program]);
    let pausedDepositEvents = events.filter((event) => event.name === "pausedDeposits");
    assert.isTrue(pausedDepositEvents[0].data.isPaused, "PausedDeposits event should indicate deposits are paused");

    // Unpause deposits as owner
    const tx2 = await program.methods.pauseDeposits(false).accounts(pauseDepositsAccounts).rpc();

    // Fetch the updated state
    stateAccountData = await program.account.state.fetch(state);
    assert.isFalse(stateAccountData.pausedDeposits, "Deposits should not be paused");

    // Verify the PausedDeposits event
    events = await readEventsUntilFound(provider.connection, tx2, [program]);
    pausedDepositEvents = events.filter((event) => event.name === "pausedDeposits");
    assert.isFalse(pausedDepositEvents[0].data.isPaused, "PausedDeposits event should indicate deposits are unpaused");

    // Try to pause deposits as non-owner
    try {
      const pauseDepositsAccounts = { state, signer: nonOwner.publicKey, program: program.programId };
      await program.methods.pauseDeposits(true).accounts(pauseDepositsAccounts).signers([nonOwner]).rpc();
      assert.fail("Non-owner should not be able to pause deposits");
    } catch (err: any) {
      assert.include(err.toString(), "Only the owner can call this function!", "Expected owner check error");
    }
  });

  it("Pauses and unpauses fills", async () => {
    assert.isFalse((await program.account.state.fetch(state)).pausedFills, "Fills should not be paused");

    // Pause fills as owner
    const pauseFillsAccounts = { state, signer: owner, program: program.programId };
    const tx = await program.methods.pauseFills(true).accounts(pauseFillsAccounts).rpc();

    // Fetch the updated state
    let stateAccountData = await program.account.state.fetch(state);
    assert.isTrue(stateAccountData.pausedFills, "Fills should be paused");

    // Verify the PausedFills event
    let events = await readEventsUntilFound(provider.connection, tx, [program]);
    let pausedFillEvents = events.filter((event) => event.name === "pausedFills");
    assert.isTrue(pausedFillEvents[0].data.isPaused, "PausedFills event should indicate fills are paused");

    // Unpause fills as owner
    const tx2 = await program.methods.pauseFills(false).accounts(pauseFillsAccounts).rpc();

    // Fetch the updated state
    stateAccountData = await program.account.state.fetch(state);
    assert.isFalse(stateAccountData.pausedFills, "Fills should not be paused");

    // Verify the PausedFills event
    events = await readEventsUntilFound(provider.connection, tx2, [program]);
    pausedFillEvents = events.filter((event) => event.name === "pausedFills");
    assert.isFalse(pausedFillEvents[0].data.isPaused, "PausedFills event should indicate fills are unpaused");

    // Try to pause fills as non-owner
    try {
      const pauseFillsAccounts = { state, signer: nonOwner.publicKey, program: program.programId };
      await program.methods.pauseFills(true).accounts(pauseFillsAccounts).signers([nonOwner]).rpc();
      assert.fail("Non-owner should not be able to pause fills");
    } catch (err: any) {
      assert.include(err.toString(), "Only the owner can call this function!", "Expected owner check error");
    }
  });

  it("Transfers ownership", async () => {
    // Transfer ownership to newOwner
    const transferOwnershipAccounts = { state, signer: owner, program: program.programId };
    const tx = await program.methods.transferOwnership(newOwner.publicKey).accounts(transferOwnershipAccounts).rpc();

    // Verify the TransferredOwnership event
    let events = await readEventsUntilFound(provider.connection, tx, [program]);
    let transferredOwnershipEvents = events.filter((event) => event.name === "transferredOwnership");
    assert.equal(
      transferredOwnershipEvents[0].data.newOwner.toString(),
      newOwner.publicKey.toString(),
      "TransferredOwnership event should indicate the new owner"
    );

    // Verify the new owner
    let stateAccountData = await program.account.state.fetch(state);
    assert.equal(stateAccountData.owner.toString(), newOwner.publicKey.toString(), "Ownership should be transferred");

    // Try to transfer ownership as non-owner
    try {
      const transferOwnershipAccounts = { state, signer: nonOwner.publicKey, program: program.programId };
      await program.methods
        .transferOwnership(nonOwner.publicKey)
        .accounts(transferOwnershipAccounts)
        .signers([nonOwner])
        .rpc();
      assert.fail("Non-owner should not be able to transfer ownership");
    } catch (err: any) {
      assert.include(err.toString(), "Only the owner can call this function!", "Expected owner check error");
    }
  });

  it("Sets cross-domain admin", async () => {
    // Set cross-domain admin as owner
    const setCrossDomainAdminAccounts = { state, signer: owner, program: program.programId };
    const tx = await program.methods
      .setCrossDomainAdmin(newCrossDomainAdmin.publicKey)
      .accounts(setCrossDomainAdminAccounts)
      .rpc();

    // Verify the new cross-domain admin
    let stateAccountData = await program.account.state.fetch(state);
    assert.equal(
      stateAccountData.crossDomainAdmin.toString(),
      newCrossDomainAdmin.publicKey.toString(),
      "Cross-domain admin should be set"
    );

    // Verify the SetXDomainAdmin event
    let events = await readEventsUntilFound(provider.connection, tx, [program]);
    let setXDomainAdminEvents = events.filter((event) => event.name === "setXDomainAdmin");
    assert.equal(
      setXDomainAdminEvents[0].data.newAdmin.toString(),
      newCrossDomainAdmin.publicKey.toString(),
      "SetXDomainAdmin event should indicate the new admin"
    );

    // Try to set cross-domain admin as non-owner
    try {
      const setCrossDomainAdminAccounts = { state, signer: nonOwner.publicKey, program: program.programId };
      await program.methods
        .setCrossDomainAdmin(nonOwner.publicKey)
        .accounts(setCrossDomainAdminAccounts)
        .signers([nonOwner])
        .rpc();
      assert.fail("Non-owner should not be able to set cross-domain admin");
    } catch (err: any) {
      assert.include(err.toString(), "Only the owner can call this function!", "Expected owner check error");
    }
  });
});
