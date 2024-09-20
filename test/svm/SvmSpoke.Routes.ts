import * as anchor from "@coral-xyz/anchor";
import { BN } from "@coral-xyz/anchor";
import { ASSOCIATED_TOKEN_PROGRAM_ID, TOKEN_PROGRAM_ID, createMint, getAccount } from "@solana/spl-token";
import { PublicKey, Keypair } from "@solana/web3.js";
import { assert } from "chai";
import { common } from "./SvmSpoke.common";
import { readProgramEvents } from "./utils";

const { provider, program, owner, initializeState, createRoutePda, getVaultAta } = common;

describe("svm_spoke.routes", () => {
  anchor.setProvider(provider);

  const nonOwner = Keypair.generate();
  let state: PublicKey, tokenMint: PublicKey;

  before("Creates token mint and associated token accounts", async () => {
    tokenMint = await createMint(provider.connection, provider.wallet.payer, owner, owner, 6);
  });

  beforeEach(async () => {
    state = await initializeState();
  });

  it("Sets, retrieves, and controls access to route enablement", async () => {
    const originToken = Keypair.generate().publicKey;
    const routeChainId = new BN(1);

    // Create a PDA for the route
    const routePda = createRoutePda(originToken, routeChainId);

    // Create ATA for the origin token to be stored by state (vault).
    const vault = getVaultAta(tokenMint, state);

    // Common accounts object
    const accounts = {
      signer: owner,
      payer: owner,
      state,
      route: routePda,
      vault: vault,
      originTokenMint: tokenMint,
      tokenProgram: TOKEN_PROGRAM_ID,
      associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
      systemProgram: anchor.web3.SystemProgram.programId,
    };

    // Enable the route as owner
    await program.methods.setEnableRoute(originToken.toBytes(), routeChainId, true).accounts(accounts).rpc();
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Retrieve and verify the route is enabled
    let routeAccount = await program.account.route.fetch(routePda);
    assert.isTrue(routeAccount.enabled, "Route should be enabled");

    // Verify the enabledDepositRoute event
    let events = (await readProgramEvents(provider.connection, program)).filter(
      (event) => event.name === "enabledDepositRoute"
    );
    let event = events[0].data;
    assert.strictEqual(event.originToken.toString(), originToken.toString(), "originToken event match");
    assert.strictEqual(event.destinationChainId.toString(), routeChainId.toString(), "destinationChainId should match");
    assert.isTrue(event.enabled, "enabledDepositRoute enabled");

    // Disable the route as owner
    await program.methods.setEnableRoute(originToken.toBytes(), routeChainId, false).accounts(accounts).rpc();
    await new Promise((resolve) => setTimeout(resolve, 500));

    // Retrieve and verify the route is disabled
    routeAccount = await program.account.route.fetch(routePda);
    assert.isFalse(routeAccount.enabled, "Route should be disabled");

    // Verify the enabledDepositRoute event
    events = (await readProgramEvents(provider.connection, program)).filter(
      (event) => event.name === "enabledDepositRoute"
    );
    event = events[0].data; // take most recent event, index 0.
    assert.strictEqual(event.originToken.toString(), originToken.toString(), "originToken event match");
    assert.strictEqual(event.destinationChainId.toString(), routeChainId.toString(), "destinationChainId should match");
    assert.isFalse(event.enabled, "enabledDepositRoute disabled");

    // Try to enable the route as non-owner
    try {
      await program.methods
        .setEnableRoute(originToken.toBytes(), routeChainId, true)
        .accounts({ ...accounts, signer: nonOwner.publicKey })
        .signers([nonOwner])
        .rpc();
      assert.fail("Non-owner should not be able to set route enablement");
    } catch (err) {
      assert.include(err.toString(), "Only the owner can call this function!", "Expected owner check error");
    }

    // Verify the route is still disabled after non-owner attempt
    routeAccount = await program.account.route.fetch(routePda);
    assert.isFalse(routeAccount.enabled, "Route should still be disabled after non-owner attempt");

    // Verify the owner of the vault is the state
    const vaultAccount = await getAccount(provider.connection, vault);
    assert.strictEqual(vaultAccount.owner.toBase58(), state.toBase58(), "Vault owner should be the state");

    // Verify the owner of the state is the expected owner
    const stateAccount = await program.account.state.fetch(state);
    assert.strictEqual(stateAccount.owner.toBase58(), owner.toBase58(), "State owner should be the expected owner");
  });
});
