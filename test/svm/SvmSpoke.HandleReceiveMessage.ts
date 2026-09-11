import * as anchor from "@coral-xyz/anchor";
import { rejects } from "assert";
import { AnchorError, AnchorProvider, BN, Program, web3, workspace } from "@coral-xyz/anchor";
import { Keypair } from "@solana/web3.js";
import { assert } from "chai";
import * as crypto from "crypto";
import { ethers } from "ethers";
import {
  CCTP_FINALITY_THRESHOLD_FINALIZED,
  encodeMessageHeaderV2,
  evmAddressToPublicKey,
  MessageHeaderV2,
} from "../../src/svm/web3-v1";
import { MessageTransmitterV2 } from "../../target/types/message_transmitter_v2";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { common } from "./SvmSpoke.common";
import { receiveCctpV2MessageOnSpoke } from "../../scripts/svm/utils/cctpV2";

const { initializeState, crossDomainAdmin, remoteDomain, localDomain } = common;

describe("svm_spoke.handle_receive_finalized_message", () => {
  anchor.setProvider(AnchorProvider.env());

  const program = workspace.SvmSpoke as Program<SvmSpoke>;
  const messageTransmitterProgram = workspace.MessageTransmitterV2 as Program<MessageTransmitterV2>;
  const provider = AnchorProvider.env();
  const owner = provider.wallet.publicKey;
  let state: web3.PublicKey;
  let seed: BN;
  let authorityPda: web3.PublicKey;
  let messageTransmitterState: web3.PublicKey;
  let selfAuthority: web3.PublicKey;
  let eventAuthority: web3.PublicKey;
  const attestation = Buffer.alloc(0); // The test validator runs the Message Transmitter with signature threshold 0.
  let nonce = Math.floor(Math.random() * 0xffffffff); // Random start so reruns never reuse a used-nonce PDA.
  let remainingAccounts: web3.AccountMeta[];
  const cctpMessageVersion = 1; // CCTP V2 message format version.
  const destinationCaller = new web3.PublicKey(new Uint8Array(32)); // We don't use permissioned caller.

  const ethereumIface = new ethers.utils.Interface([
    "function pauseDeposits(bool pause)",
    "function pauseFills(bool pause)",
    "function setCrossDomainAdmin(address newCrossDomainAdmin)",
    "function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot)",
    "function emergencyDeleteRootBundle(uint256 rootBundleId)",
  ]);

  const encodeCalldata = (fn: string, args: unknown[]) =>
    Buffer.from(ethereumIface.encodeFunctionData(fn, args).slice(2), "hex");

  // Encodes an attested CCTP V2 message with a fresh nonce and resolves the receive_message accounts for it.
  const buildMessage = (messageBody: Buffer, overrides: Partial<MessageHeaderV2> = {}) => {
    nonce += 1;
    const header: MessageHeaderV2 = {
      version: cctpMessageVersion,
      sourceDomain: remoteDomain.toNumber(),
      destinationDomain: localDomain,
      nonce: BigInt(nonce),
      sender: crossDomainAdmin,
      recipient: program.programId,
      destinationCaller,
      minFinalityThreshold: CCTP_FINALITY_THRESHOLD_FINALIZED,
      finalityThresholdExecuted: CCTP_FINALITY_THRESHOLD_FINALIZED,
      messageBody,
      ...overrides,
    };
    const message = encodeMessageHeaderV2(header);
    // CCTP V2 tracks each nonce in its own PDA seeded by the 32-byte nonce at header offset 12.
    const [usedNonce] = web3.PublicKey.findProgramAddressSync(
      [Buffer.from("used_nonce"), message.subarray(12, 44)],
      messageTransmitterProgram.programId
    );
    const accounts = {
      payer: owner,
      caller: owner,
      authorityPda,
      messageTransmitter: messageTransmitterState,
      usedNonce,
      receiver: program.programId,
      systemProgram: web3.SystemProgram.programId,
      program: messageTransmitterProgram.programId,
    };
    return { message, accounts };
  };

  const receiveMessage = (built: ReturnType<typeof buildMessage>, accounts: web3.AccountMeta[] = remainingAccounts) =>
    messageTransmitterProgram.methods
      .receiveMessage({ message: built.message, attestation })
      .accounts(built.accounts)
      .remainingAccounts(accounts)
      .rpc();

  beforeEach(async () => {
    ({ state, seed } = await initializeState());

    // Get other required accounts.
    [authorityPda] = web3.PublicKey.findProgramAddressSync(
      [Buffer.from("message_transmitter_authority"), program.programId.toBuffer()],
      messageTransmitterProgram.programId
    );
    [messageTransmitterState] = web3.PublicKey.findProgramAddressSync(
      [Buffer.from("message_transmitter")],
      messageTransmitterProgram.programId
    );
    [selfAuthority] = web3.PublicKey.findProgramAddressSync([Buffer.from("self_authority")], program.programId);
    [eventAuthority] = web3.PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], program.programId);

    remainingAccounts = [];
    // state in HandleReceiveFinalizedMessage accounts (used for remote domain and sender authentication).
    remainingAccounts.push({ isSigner: false, isWritable: false, pubkey: state });
    // self_authority in HandleReceiveFinalizedMessage accounts, also signer in self-invoked CPIs.
    remainingAccounts.push({ isSigner: false, isWritable: false, pubkey: selfAuthority });
    // program in HandleReceiveFinalizedMessage accounts.
    remainingAccounts.push({ isSigner: false, isWritable: false, pubkey: program.programId });
    // state in self-invoked CPIs (state can change as a result of remote call).
    remainingAccounts.push({ isSigner: false, isWritable: true, pubkey: state });
    // event_authority in self-invoked CPIs (appended by Anchor with event_cpi macro).
    remainingAccounts.push({ isSigner: false, isWritable: false, pubkey: eventAuthority });
    // program in self-invoked CPIs (appended by Anchor with event_cpi macro).
    remainingAccounts.push({ isSigner: false, isWritable: false, pubkey: program.programId });
  });

  it("Script finalizer delivers all supported calls and safely resumes after delivery", async () => {
    await waitForConfirmedState();
    const deliver = (built: ReturnType<typeof buildMessage>) =>
      receiveCctpV2MessageOnSpoke(provider, program, state, built.message, attestation, messageTransmitterProgram);
    const pause = buildMessage(encodeCalldata("pauseDeposits", [true]));
    assert.isString(await deliver(pause));
    assert.isTrue((await program.account.state.fetch(state)).pausedDeposits);
    assert.isNull(await deliver(pause));
    await deliver(buildMessage(encodeCalldata("pauseFills", [true])));
    assert.isTrue((await program.account.state.fetch(state)).pausedFills);

    const rootId = (await program.account.state.fetch(state)).rootBundleId;
    const refundRoot = crypto.randomBytes(32);
    const slowRoot = crypto.randomBytes(32);
    const roots = buildMessage(encodeCalldata("relayRootBundle", [refundRoot, slowRoot]));
    await deliver(roots);
    assert.isNull(await deliver(roots));
    assert.equal((await program.account.state.fetch(state)).rootBundleId, rootId + 1);
    const rootIdBytes = Buffer.alloc(4);
    rootIdBytes.writeUInt32LE(rootId);
    const [rootBundle] = web3.PublicKey.findProgramAddressSync(
      [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootIdBytes],
      program.programId
    );
    const rootData = await program.account.rootBundle.fetch(rootBundle);
    assert.deepEqual(Buffer.from(rootData.relayerRefundRoot), refundRoot);
    assert.deepEqual(Buffer.from(rootData.slowRelayRoot), slowRoot);
    const deletion = buildMessage(encodeCalldata("emergencyDeleteRootBundle", [rootId]));
    await deliver(deletion);
    assert.isNull(await program.account.rootBundle.fetchNullable(rootBundle));
    assert.isNull(await deliver(deletion));

    const newAdmin = ethers.Wallet.createRandom().address;
    const changeAdmin = buildMessage(encodeCalldata("setCrossDomainAdmin", [newAdmin]));
    await deliver(changeAdmin);
    assert.isTrue((await program.account.state.fetch(state)).crossDomainAdmin.equals(evmAddressToPublicKey(newAdmin)));
    // The old sender no longer matches state, but its already-delivered message remains a successful no-op.
    assert.isNull(await deliver(changeAdmin));
  });

  it("Script finalizer leaves a failed nonce retryable", async () => {
    await waitForConfirmedState();
    const built = buildMessage(encodeCalldata("pauseDeposits", [true]));
    const deliver = (message: Buffer) =>
      receiveCctpV2MessageOnSpoke(provider, program, state, message, attestation, messageTransmitterProgram);
    const wrongSender = Buffer.from(built.message);
    Keypair.generate().publicKey.toBuffer().copy(wrongSender, 44);
    try {
      await deliver(wrongSender);
      assert.fail("Unauthorized message should fail");
    } catch (error: any) {
      assert.include(error.message, "remote domain and admin");
    }
    assert.isNull(await messageTransmitterProgram.account.usedNonce.fetchNullable(built.accounts.usedNonce));
    assert.isString(await deliver(built.message));
  });

  it("Script finalizer uses the finalized threshold boundary from message bytes", async () => {
    await waitForConfirmedState();
    for (const threshold of [1000, 1500, 1999, 2000, 2500]) {
      const built = buildMessage(encodeCalldata("pauseDeposits", [true]), { finalityThresholdExecuted: threshold });
      const delivery = receiveCctpV2MessageOnSpoke(
        provider,
        program,
        state,
        built.message,
        attestation,
        messageTransmitterProgram
      );
      if (threshold < 2000) await rejects(delivery, /require finalized attestations/);
      else assert.isString(await delivery);
    }
  });

  async function waitForConfirmedState() {
    // initializeState uses Anchor's processed commitment; operational finalization deliberately reads confirmed state.
    const { context } = await provider.connection.getAccountInfoAndContext(state, "processed");
    while ((await provider.connection.getSlot("confirmed")) < context.slot)
      await new Promise((resolve) => setTimeout(resolve, 100));
  }

  it("Block Unauthorized Message", async () => {
    const unauthorizedSender = Keypair.generate().publicKey;
    const built = buildMessage(encodeCalldata("pauseDeposits", [true]), { sender: unauthorizedSender });

    try {
      await receiveMessage(built);
      assert.fail("Should not be able to receive message from unauthorized sender");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(error.error.errorCode.code, "InvalidRemoteSender", "Expected error code InvalidRemoteSender");
    }
  });

  it("Block Wrong Source Domain", async () => {
    const built = buildMessage(encodeCalldata("pauseDeposits", [true]), { sourceDomain: 666 });

    try {
      await receiveMessage(built);
      assert.fail("Should not be able to receive message from wrong source domain");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(error.error.errorCode.code, "InvalidRemoteDomain", "Expected error code InvalidRemoteDomain");
    }
  });

  it("Block Unfinalized Message", async () => {
    // The Message Transmitter routes messages attested below the finalized threshold to
    // handle_receive_unfinalized_message, which this program intentionally does not implement.
    const built = buildMessage(encodeCalldata("pauseDeposits", [true]), {
      minFinalityThreshold: 1000,
      finalityThresholdExecuted: 1000,
    });

    try {
      await receiveMessage(built);
      assert.fail("Should not be able to receive unfinalized message");
    } catch (error: any) {
      assert.instanceOf(error, AnchorError);
      assert.strictEqual(
        error.error.errorCode.code,
        "InstructionFallbackNotFound",
        "Expected error code InstructionFallbackNotFound"
      );
    }
    const stateData = await program.account.state.fetch(state);
    assert.isFalse(stateData.pausedDeposits, "Deposits should not be paused");
  });

  it("Pauses and unpauses deposits remotely", async () => {
    // Pause deposits.
    await receiveMessage(buildMessage(encodeCalldata("pauseDeposits", [true])));
    let stateData = await program.account.state.fetch(state);
    assert.isTrue(stateData.pausedDeposits, "Deposits should be paused");

    // Unpause deposits.
    await receiveMessage(buildMessage(encodeCalldata("pauseDeposits", [false])));
    stateData = await program.account.state.fetch(state);
    assert.isFalse(stateData.pausedDeposits, "Deposits should not be paused");
  });

  it("Pauses and unpauses fills remotely", async () => {
    // Pause fills.
    await receiveMessage(buildMessage(encodeCalldata("pauseFills", [true])));
    let stateData = await program.account.state.fetch(state);
    assert.isTrue(stateData.pausedFills, "Fills should be paused");

    // Unpause fills.
    await receiveMessage(buildMessage(encodeCalldata("pauseFills", [false])));
    stateData = await program.account.state.fetch(state);
    assert.isFalse(stateData.pausedFills, "Fills should not be paused");
  });

  it("Sets cross-domain admin remotely", async () => {
    const newCrossDomainAdminAddress = ethers.Wallet.createRandom().address;
    const newCrossDomainAdminPubkey = evmAddressToPublicKey(newCrossDomainAdminAddress);
    await receiveMessage(buildMessage(encodeCalldata("setCrossDomainAdmin", [newCrossDomainAdminAddress])));
    const stateData = await program.account.state.fetch(state);
    assert.strictEqual(
      stateData.crossDomainAdmin.toString(),
      newCrossDomainAdminPubkey.toString(),
      "Cross-domain admin should be set"
    );
  });

  it("Relays root bundle remotely", async () => {
    // Encode relayRootBundle message.
    const relayerRefundRoot = crypto.randomBytes(32);
    const slowRelayRoot = crypto.randomBytes(32);
    const built = buildMessage(encodeCalldata("relayRootBundle", [relayerRefundRoot, slowRelayRoot]));

    // Remaining accounts specific to RelayRootBundle.
    const rootBundleId = (await program.account.state.fetch(state)).rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = web3.PublicKey.findProgramAddressSync(seeds, program.programId);
    // Same 3 remaining accounts passed for HandleReceiveFinalizedMessage context.
    const relayRootBundleRemainingAccounts = remainingAccounts.slice(0, 3);
    // payer in self-invoked RelayRootBundle.
    relayRootBundleRemainingAccounts.push({ isSigner: true, isWritable: true, pubkey: provider.wallet.publicKey });
    // state in self-invoked RelayRootBundle.
    relayRootBundleRemainingAccounts.push({ isSigner: false, isWritable: true, pubkey: state });
    // root_bundle in self-invoked RelayRootBundle.
    relayRootBundleRemainingAccounts.push({ isSigner: false, isWritable: true, pubkey: rootBundle });
    // system_program in self-invoked RelayRootBundle.
    relayRootBundleRemainingAccounts.push({ isSigner: false, isWritable: false, pubkey: web3.SystemProgram.programId });
    // event_authority in self-invoked RelayRootBundle (appended by Anchor with event_cpi macro).
    relayRootBundleRemainingAccounts.push({ isSigner: false, isWritable: false, pubkey: eventAuthority });
    // program in self-invoked RelayRootBundle (appended by Anchor with event_cpi macro).
    relayRootBundleRemainingAccounts.push({ isSigner: false, isWritable: false, pubkey: program.programId });

    // Invoke remote CCTP message to relay root bundle.
    await receiveMessage(built, relayRootBundleRemainingAccounts);

    // Check the updated relayer refund and slow relay root in the root bundle account.
    const rootBundleAccountData = await program.account.rootBundle.fetch(rootBundle);
    const updatedRelayerRefundRoot = Buffer.from(rootBundleAccountData.relayerRefundRoot);
    const updatedSlowRelayRoot = Buffer.from(rootBundleAccountData.slowRelayRoot);
    assert.isTrue(updatedRelayerRefundRoot.equals(relayerRefundRoot), "Relayer refund root should be set");
    assert.isTrue(updatedSlowRelayRoot.equals(slowRelayRoot), "Slow relay root should be set");
  });

  it("Emergency deletes root bundle remotely", async () => {
    // Relay root bundle.
    const relayerRefundRoot = crypto.randomBytes(32);
    const slowRelayRoot = crypto.randomBytes(32);
    const rootBundleId = (await program.account.state.fetch(state)).rootBundleId;
    const rootBundleIdBuffer = Buffer.alloc(4);
    rootBundleIdBuffer.writeUInt32LE(rootBundleId);
    const seeds = [Buffer.from("root_bundle"), seed.toArrayLike(Buffer, "le", 8), rootBundleIdBuffer];
    const [rootBundle] = web3.PublicKey.findProgramAddressSync(seeds, program.programId);
    const relayRootBundleAccounts = { state, rootBundle, signer: owner, payer: owner, program: program.programId };
    await program.methods
      .relayRootBundle(Array.from(relayerRefundRoot), Array.from(slowRelayRoot))
      .accounts(relayRootBundleAccounts)
      .rpc();

    // Ensure the root bundle exists before deletion
    let rootBundleData = await program.account.rootBundle.fetch(rootBundle);
    assert.isNotNull(rootBundleData, "Root bundle should exist before deletion");

    // Encode emergencyDeleteRootBundle message.
    const built = buildMessage(encodeCalldata("emergencyDeleteRootBundle", [rootBundleId]));

    // Remaining accounts specific to EmergencyDeletedRootBundle.
    // Same 3 remaining accounts passed for HandleReceiveFinalizedMessage context.
    const emergencyDeleteRootBundleRemainingAccounts = remainingAccounts.slice(0, 3);
    // closer in self-invoked EmergencyDeletedRootBundle.
    emergencyDeleteRootBundleRemainingAccounts.push({
      isSigner: true,
      isWritable: true,
      pubkey: provider.wallet.publicKey,
    });
    // state in self-invoked EmergencyDeletedRootBundle.
    emergencyDeleteRootBundleRemainingAccounts.push({ isSigner: false, isWritable: false, pubkey: state });
    // root_bundle in self-invoked EmergencyDeletedRootBundle.
    emergencyDeleteRootBundleRemainingAccounts.push({ isSigner: false, isWritable: true, pubkey: rootBundle });
    // event_authority in self-invoked EmergencyDeletedRootBundle (appended by Anchor with event_cpi macro).
    emergencyDeleteRootBundleRemainingAccounts.push({ isSigner: false, isWritable: false, pubkey: eventAuthority });
    // program in self-invoked EmergencyDeletedRootBundle (appended by Anchor with event_cpi macro).
    emergencyDeleteRootBundleRemainingAccounts.push({ isSigner: false, isWritable: false, pubkey: program.programId });

    // Invoke remote CCTP message to delete the root bundle.
    await receiveMessage(built, emergencyDeleteRootBundleRemainingAccounts);

    // Verify that the root bundle has been deleted
    try {
      rootBundleData = await program.account.rootBundle.fetch(rootBundle);
      assert.fail("Root bundle should have been deleted");
    } catch (err: any) {
      assert.include(
        err.toString(),
        "Account does not exist or has no data",
        "Expected error when fetching deleted root bundle"
      );
    }
  });

  it("Replaying an old message is not possible", async () => {
    // Pause fills.
    await receiveMessage(buildMessage(encodeCalldata("pauseFills", [true])));
    let stateData = await program.account.state.fetch(state);
    assert.isTrue(stateData.pausedFills, "Fills should be paused");

    // Unpause fills.
    const unpause = buildMessage(encodeCalldata("pauseFills", [false]));
    await receiveMessage(unpause);
    stateData = await program.account.state.fetch(state);
    assert.isFalse(stateData.pausedFills, "Fills should not be paused");

    // Replaying the unpause message fails as its used_nonce PDA already exists.
    try {
      await receiveMessage(unpause);
      assert.fail("Should not be able to replay unpause message");
    } catch (error: any) {
      const errorText = [error.toString(), ...(error.logs ?? [])].join("\n");
      assert.include(errorText, "already in use", "Expected used nonce account to already exist");
    }
  });
});
