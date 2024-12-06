import * as anchor from "@coral-xyz/anchor";
import { BN, workspace, web3, AnchorProvider, Wallet, Program, AnchorError } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { TOKEN_PROGRAM_ID, createMint, getOrCreateAssociatedTokenAccount, mintTo } from "@solana/spl-token";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import { common } from "./SvmSpoke.common";
import { MessageTransmitter } from "../../target/types/message_transmitter";
import { TokenMessengerMinter } from "../../target/types/token_messenger_minter";
import { assert } from "chai";
import { decodeMessageSentData } from "./cctpHelpers";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../src/types/svm";
import {
  findProgramAddress,
  loadExecuteRelayerRefundLeafParams,
  readEventsUntilFound,
  relayerRefundHashFn,
} from "../../src/svm";

const { provider, program, owner, initializeState, connection, remoteDomain, chainId, crossDomainAdmin } = common;

describe("svm_spoke.token_bridge", () => {
  anchor.setProvider(provider);

  const tokenMessengerMinterProgram = workspace.TokenMessengerMinter as Program<TokenMessengerMinter>;
  const messageTransmitterProgram = workspace.MessageTransmitter as Program<MessageTransmitter>;

  let state: PublicKey,
    seed: BN,
    mint: PublicKey,
    vault: PublicKey,
    tokenMinter: PublicKey,
    messageTransmitter: PublicKey,
    tokenMessenger: PublicKey,
    remoteTokenMessenger: PublicKey,
    eventAuthority: PublicKey,
    transferLiability: PublicKey,
    localToken: PublicKey,
    tokenMessengerMinterSenderAuthority: PublicKey;

  let messageSentEventData: web3.Keypair; // This will hold CCTP message data.

  let bridgeTokensToHubPoolAccounts: any;

  const payer = (AnchorProvider.env().wallet as Wallet).payer;

  const initialMintAmount = 10_000_000_000;

  before(async () => {
    // token_minter state is pulled from devnet (DBD8hAwLDRQkTsu6EqviaYNGKPnsAMmQonxf7AH8ZcFY) with its
    // token_controller field overridden to test wallet.
    tokenMinter = findProgramAddress("token_minter", tokenMessengerMinterProgram.programId).publicKey;

    // message_transmitter state is forked from devnet (BWrwSWjbikT3H7qHAkUEbLmwDQoB4ZDJ4wcSEhSPTZCu).
    messageTransmitter = findProgramAddress("message_transmitter", messageTransmitterProgram.programId).publicKey;

    // token_messenger state is forked from devnet (Afgq3BHEfCE7d78D2XE9Bfyu2ieDqvE24xX8KDwreBms).
    tokenMessenger = findProgramAddress("token_messenger", tokenMessengerMinterProgram.programId).publicKey;

    // Ethereum remote_token_messenger state is forked from devnet (Hazwi3jFQtLKc2ughi7HFXPkpDeso7DQaMR9Ks4afh3j).
    remoteTokenMessenger = findProgramAddress("remote_token_messenger", tokenMessengerMinterProgram.programId, [
      remoteDomain.toString(),
    ]).publicKey;

    // PDA for token_messenger_minter to emit DepositForBurn event via CPI.
    eventAuthority = findProgramAddress("__event_authority", tokenMessengerMinterProgram.programId).publicKey;

    // PDA, used to check that CCTP sendMessage was called by TokenMessenger
    tokenMessengerMinterSenderAuthority = findProgramAddress(
      "sender_authority",
      tokenMessengerMinterProgram.programId
    ).publicKey;
  });

  beforeEach(async () => {
    // Each test will have different state and mint token.
    ({ state, seed } = await initializeState());
    mint = await createMint(connection, payer, owner, owner, 6);
    vault = (await getOrCreateAssociatedTokenAccount(connection, payer, mint, state, true)).address;

    await mintTo(connection, payer, mint, vault, provider.publicKey, initialMintAmount);

    transferLiability = findProgramAddress("transfer_liability", program.programId, [mint as any]).publicKey;
    localToken = findProgramAddress("local_token", tokenMessengerMinterProgram.programId, [mint as any]).publicKey;

    // add local cctp token
    const custodyTokenAccount = findProgramAddress("custody", tokenMessengerMinterProgram.programId, [
      mint as any,
    ]).publicKey;
    const addLocalTokenAccounts = {
      tokenController: owner,
      tokenMinter,
      localToken,
      custodyTokenAccount,
      localTokenMint: mint,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: web3.SystemProgram.programId,
      program: tokenMessengerMinterProgram.programId,
      eventAuthority,
    };
    await tokenMessengerMinterProgram.methods.addLocalToken({}).accounts(addLocalTokenAccounts).rpc();

    // set max burn amount per CCTP message for local token to total mint amount.
    const setMaxBurnAmountPerMessageAccounts = {
      tokenMinter,
      localToken,
      program: tokenMessengerMinterProgram.programId,
      eventAuthority,
    };
    await tokenMessengerMinterProgram.methods
      .setMaxBurnAmountPerMessage({ burnLimitPerMessage: new BN(initialMintAmount) })
      .accounts(setMaxBurnAmountPerMessageAccounts)
      .rpc();

    // Populate accounts for bridgeTokensToHubPool.
    messageSentEventData = web3.Keypair.generate();
    bridgeTokensToHubPoolAccounts = {
      payer: owner,
      mint,
      state,
      transferLiability,
      vault,
      tokenMessengerMinterSenderAuthority,
      messageTransmitter,
      tokenMessenger,
      remoteTokenMessenger,
      tokenMinter,
      localToken,
      messageSentEventData: messageSentEventData.publicKey,
      messageTransmitterProgram: messageTransmitterProgram.programId,
      tokenMessengerMinterProgram: tokenMessengerMinterProgram.programId,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: web3.SystemProgram.programId,
      cctpEventAuthority: eventAuthority,
    };
  });

  const initializeBridgeToHubPool = async (amountToReturn: number) => {
    // Prepare root bundle with a single leaf containing amount to bridge to the HubPool.
    const relayerRefundLeaves: RelayerRefundLeafType[] = [];
    relayerRefundLeaves.push({
      isSolana: true,
      leafId: new BN(0),
      chainId,
      amountToReturn: new BN(amountToReturn),
      mintPublicKey: mint,
      refundAddresses: [],
      refundAmounts: [],
    });
    const merkleTree = new MerkleTree<RelayerRefundLeafType>(relayerRefundLeaves, relayerRefundHashFn);
    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[0]);
    const leaf = relayerRefundLeaves[0] as RelayerRefundLeafSolana;
    const stateAccountData = await program.account.state.fetch(state);
    const rootBundleId = stateAccountData.rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = PublicKey.findProgramAddressSync(seeds, program.programId);

    // Relay root bundle
    const relayRootBundleAccounts = {
      state,
      rootBundle,
      signer: owner,
      payer: owner,
      program: program.programId,
    };
    await program.methods
      .relayRootBundle(Array.from(root), Array.from(Buffer.alloc(32)))
      .accounts(relayRootBundleAccounts)
      .rpc();

    // Execute relayer refund leaf.
    const proofAsNumbers = proof.map((p) => Array.from(p));
    const executeRelayerRefundLeafAccounts = {
      state,
      rootBundle,
      signer: owner,
      vault,
      mint,
      transferLiability,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: web3.SystemProgram.programId,
      program: program.programId,
    };
    await loadExecuteRelayerRefundLeafParams(program, owner, stateAccountData.rootBundleId, leaf, proofAsNumbers);
    await program.methods.executeRelayerRefundLeaf().accounts(executeRelayerRefundLeafAccounts).rpc();
  };

  it("Bridge all pending tokens to HubPool in single transaction", async () => {
    const pendingToHubPool = 1_000_000;

    await initializeBridgeToHubPool(pendingToHubPool);

    const initialVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(initialVaultBalance, initialMintAmount.toString());

    await program.methods
      .bridgeTokensToHubPool(new BN(pendingToHubPool))
      .accounts(bridgeTokensToHubPoolAccounts)
      .signers([messageSentEventData])
      .rpc();

    const finalVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(finalVaultBalance, (initialMintAmount - pendingToHubPool).toString());

    const finalPendingToHubPool = (await program.account.transferLiability.fetch(transferLiability)).pendingToHubPool;
    assert.isTrue(finalPendingToHubPool.isZero(), "Invalid pending to HubPool amount");

    const message = decodeMessageSentData(
      (await messageTransmitterProgram.account.messageSent.fetch(messageSentEventData.publicKey)).message
    );
    assert.strictEqual(message.destinationDomain, remoteDomain.toNumber(), "Invalid destination domain");
    assert.isTrue(message.messageBody.burnToken.equals(mint), "Invalid burn token");
    assert.isTrue(message.messageBody.mintRecipient.equals(crossDomainAdmin), "Invalid mint recipient");
    assert.strictEqual(message.messageBody.amount.toString(), pendingToHubPool.toString(), "Invalid amount");
  });

  it("Bridge above pending tokens in single transaction to HubPool should fail", async () => {
    const pendingToHubPool = 1_000_000;
    const bridgeAmount = pendingToHubPool + 1;

    await initializeBridgeToHubPool(pendingToHubPool);

    try {
      await program.methods
        .bridgeTokensToHubPool(new BN(bridgeAmount))
        .accounts(bridgeTokensToHubPoolAccounts)
        .signers([messageSentEventData])
        .rpc();
      assert.fail("Should not be able to bridge above pending tokens to HubPool");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(
        error.error.errorCode.code,
        "ExceededPendingBridgeAmount",
        "Expected error code ExceededPendingBridgeAmount"
      );
    }
  });

  it("Bridge pending tokens to HubPool in multiple transactions", async () => {
    const pendingToHubPool = 10_000_000;
    const singleBridgeAmount = pendingToHubPool / 5;

    await initializeBridgeToHubPool(pendingToHubPool);

    const initialVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(initialVaultBalance, initialMintAmount.toString());

    for (let i = 0; i < 5; i++) {
      const loopMessageSentEventData = web3.Keypair.generate();

      await program.methods
        .bridgeTokensToHubPool(new BN(singleBridgeAmount))
        .accounts({ ...bridgeTokensToHubPoolAccounts, messageSentEventData: loopMessageSentEventData.publicKey })
        .signers([loopMessageSentEventData])
        .rpc();
    }

    const finalVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(finalVaultBalance, (initialMintAmount - pendingToHubPool).toString());

    const finalPendingToHubPool = (await program.account.transferLiability.fetch(transferLiability)).pendingToHubPool;
    assert.isTrue(finalPendingToHubPool.isZero(), "Invalid pending to HubPool amount");
  });

  it("Bridge above pending tokens in multiple transactions to HubPool should fail", async () => {
    const pendingToHubPool = 10_000_000;
    const singleBridgeAmount = pendingToHubPool / 5;

    await initializeBridgeToHubPool(pendingToHubPool);

    const initialVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(initialVaultBalance, initialMintAmount.toString());

    // Bridge out first 4 tranches.
    for (let i = 0; i < 4; i++) {
      const loopMessageSentEventData = web3.Keypair.generate();

      await program.methods
        .bridgeTokensToHubPool(new BN(singleBridgeAmount))
        .accounts({ ...bridgeTokensToHubPoolAccounts, messageSentEventData: loopMessageSentEventData.publicKey })
        .signers([loopMessageSentEventData])
        .rpc();
    }

    // Try to bridge out more tokens in the final tranche.
    try {
      await program.methods
        .bridgeTokensToHubPool(new BN(singleBridgeAmount + 1))
        .accounts(bridgeTokensToHubPoolAccounts)
        .signers([messageSentEventData])
        .rpc();
      assert.fail("Should not be able to bridge above pending tokens to HubPool");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(
        error.error.errorCode.code,
        "ExceededPendingBridgeAmount",
        "Expected error code ExceededPendingBridgeAmount"
      );
    }
  });

  it("Test BridgedToHubPool event", async () => {
    const simpleBridgeAmount = 500_000;

    // Initialize the bridge with a specific amount.
    await initializeBridgeToHubPool(simpleBridgeAmount);

    const initialVaultBalance = (await connection.getTokenAccountBalance(vault)).value.amount;
    assert.strictEqual(initialVaultBalance, initialMintAmount.toString());

    // Create a new Keypair for the message event data.
    const simpleBridgeMessageSentEventData = web3.Keypair.generate();

    // Perform the bridge operation.
    const tx = await program.methods
      .bridgeTokensToHubPool(new BN(simpleBridgeAmount))
      .accounts({ ...bridgeTokensToHubPoolAccounts, messageSentEventData: simpleBridgeMessageSentEventData.publicKey })
      .signers([simpleBridgeMessageSentEventData])
      .rpc();

    const events = await readEventsUntilFound(connection, tx, [program]);
    const event = events.find((event) => event.name === "bridgedToHubPool")?.data;
    assert.isNotNull(event, "BridgedToHubPool event should be emitted");
    assert.strictEqual(event.amount.toString(), simpleBridgeAmount.toString(), "Invalid amount");
    assert.strictEqual(event.mint.toString(), mint.toString(), "Invalid mint");
  });
});
