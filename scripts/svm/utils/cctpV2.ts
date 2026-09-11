import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { AccountMeta, PublicKey, SystemProgram } from "@solana/web3.js";
import { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { ethers } from "ethers";
import { array, create, enums, string, type } from "superstruct";
import { decodeMessageHeaderV2, decodeTokenMessengerV2MessageBody } from "../../../src/svm/web3-v1/cctpV2Helpers";
import { CCTP_FINALITY_THRESHOLD_FINALIZED } from "../../../src/svm/web3-v1/constants";
import {
  getMessageTransmitterV2Program,
  getSpokePoolProgram,
  getTokenMessengerMinterV2Program,
} from "../../../src/svm/web3-v1/programConnectors";

// Validate only consumed fields. Finality and recipient come from the attested bytes, not Iris's decoded metadata.
const scriptAttestationResponse = type({
  messages: array(
    type({
      message: string(),
      attestation: string(),
      cctpVersion: enums([1, 2]),
      status: enums(["complete", "pending_confirmations"]),
    })
  ),
});

const spokeInterface = new ethers.utils.Interface([
  "function pauseDeposits(bool pause)",
  "function pauseFills(bool pause)",
  "function setCrossDomainAdmin(address newCrossDomainAdmin)",
  "function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot)",
  "function emergencyDeleteRootBundle(uint256 rootBundleId)",
]);

/** Script-only polling: bounded, V2-only, and tolerant of messages not yet indexed by Iris. */
export async function fetchCctpV2Messages(
  txHash: string,
  sourceDomain: number,
  irisApiUrl: string,
  timeoutMs = 120_000
): Promise<{ message: Buffer; attestation: Buffer }[]> {
  if (!/^0x[0-9a-fA-F]{64}$/.test(txHash)) throw new Error("Expected an EVM source transaction hash");
  if (!Number.isInteger(sourceDomain) || sourceDomain < 0 || sourceDomain > 0xffffffff)
    throw new Error("Invalid CCTP source domain");
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("Timeout must be positive");

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const response = await fetch(`${irisApiUrl}/v2/messages/${sourceDomain}?transactionHash=${txHash}`, {
      signal: AbortSignal.timeout(Math.min(10_000, Math.max(1, deadline - Date.now()))),
    });
    if (response.ok) {
      const body = create(await response.json(), scriptAttestationResponse);
      const messages = body.messages.filter(({ cctpVersion }) => cctpVersion === 2);
      if (body.messages.length && !messages.length) throw new Error("Source transaction contains no CCTP V2 messages");
      if (messages.length && messages.every(({ status }) => status === "complete")) {
        return messages.map(({ message, attestation }) => {
          if (!ethers.utils.isHexString(message) || !ethers.utils.isHexString(attestation) || message === "0x")
            throw new Error("Invalid completed CCTP V2 attestation response");
          return {
            message: Buffer.from(ethers.utils.arrayify(message)),
            attestation: Buffer.from(ethers.utils.arrayify(attestation)),
          };
        });
      }
    } else if (response.status !== 404 && response.status !== 429 && response.status < 500) {
      throw new Error(`CCTP attestation request failed: HTTP ${response.status}`);
    }
    await new Promise((resolve) => setTimeout(resolve, Math.min(2000, Math.max(0, deadline - Date.now()))));
  }
  throw new Error(`Timed out waiting for CCTP V2 attestations for ${txHash}; rerun with the same source transaction`);
}

/** Resolve the self-CPI accounts for every Solidity selector supported by the spoke's message receiver. */
export function getCctpV2SpokeAccounts(
  programId: PublicKey,
  statePda: PublicKey,
  state: { seed: BN; rootBundleId: number },
  payer: PublicKey,
  messageBody: Buffer
): AccountMeta[] {
  const call = spokeInterface.parseTransaction({ data: ethers.utils.hexlify(messageBody) });
  const stateAccount = { pubkey: statePda, isSigner: false, isWritable: true };
  const accounts: AccountMeta[] = [stateAccount];
  if (call.name === "relayRootBundle" || call.name === "emergencyDeleteRootBundle") {
    const rootBundleId = call.name === "relayRootBundle" ? state.rootBundleId : call.args.rootBundleId.toNumber();
    const rootId = Buffer.alloc(4);
    rootId.writeUInt32LE(rootBundleId);
    const [rootBundle] = PublicKey.findProgramAddressSync(
      [Buffer.from("root_bundle"), state.seed.toArrayLike(Buffer, "le", 8), rootId],
      programId
    );
    stateAccount.isWritable = call.name === "relayRootBundle";
    accounts.unshift({ pubkey: payer, isSigner: call.name === "relayRootBundle", isWritable: true });
    accounts.push({ pubkey: rootBundle, isSigner: false, isWritable: true });
    if (call.name === "relayRootBundle")
      accounts.push({ pubkey: SystemProgram.programId, isSigner: false, isWritable: false });
  }
  const [eventAuthority] = PublicKey.findProgramAddressSync([Buffer.from("__event_authority")], programId);
  return [
    ...accounts,
    { pubkey: eventAuthority, isSigner: false, isWritable: false },
    { pubkey: programId, isSigner: false, isWritable: false },
  ];
}

/** Resolve token accounts from Circle's mapping, and require the intended destination token account. */
export async function getCctpV2TokenAccounts(
  program: ReturnType<typeof getTokenMessengerMinterV2Program>,
  statePda: PublicKey,
  header: ReturnType<typeof decodeMessageHeaderV2>,
  expectedTokenRecipient?: PublicKey
): Promise<AccountMeta[]> {
  if (header.messageBody.length < 228) throw new Error("Invalid CCTP V2 burn message body");
  const body = decodeTokenMessengerV2MessageBody(header.messageBody);
  if (body.version !== 1) throw new Error("Expected CCTP V2 burn format version 1");
  const pda = (name: string, ...seeds: Buffer[]) =>
    PublicKey.findProgramAddressSync([Buffer.from(name), ...seeds], program.programId)[0];
  const domain = Buffer.from(header.sourceDomain.toString());
  const tokenPair = pda("token_pair", domain, body.burnToken.toBuffer());
  const pair = await program.account.tokenPair.fetch(tokenPair, "confirmed");
  const localToken = await program.account.localToken.fetch(pair.localToken, "confirmed");
  const expected = expectedTokenRecipient ?? getAssociatedTokenAddressSync(localToken.mint, statePda, true);
  if (!body.mintRecipient.equals(expected))
    throw new Error(`Token recipient does not match expected token account ${expected}`);
  const tokenMessenger = pda("token_messenger");
  const messenger = await program.account.tokenMessenger.fetch(tokenMessenger, "confirmed");
  const accounts: [PublicKey, boolean][] = [
    [tokenMessenger, false],
    [pda("remote_token_messenger", domain), false],
    [pda("token_minter"), false],
    [pair.localToken, true],
    [tokenPair, false],
    [getAssociatedTokenAddressSync(localToken.mint, messenger.feeRecipient, true), true],
    [body.mintRecipient, true],
    [localToken.custody, true],
    [TOKEN_PROGRAM_ID, false],
    [pda("__event_authority"), false],
    [program.programId, false],
  ];
  return accounts.map(([pubkey, isWritable]) => ({ pubkey, isWritable, isSigner: false }));
}

/** Shared receive/nonce/retry plumbing; receiver-specific checks and accounts stay in the wrappers. */
async function receiveCctpV2Message(
  provider: AnchorProvider,
  receiver: PublicKey,
  message: Buffer,
  attestation: Buffer,
  messageTransmitterProgram: ReturnType<typeof getMessageTransmitterV2Program>,
  buildAccounts: (header: ReturnType<typeof decodeMessageHeaderV2>) => Promise<AccountMeta[]>
): Promise<string | null> {
  if (message.length < 148) throw new Error("Invalid CCTP V2 message header");
  const header = decodeMessageHeaderV2(message);
  if (header.version !== 1) throw new Error("Expected CCTP V2 message format version 1");
  if (header.destinationDomain !== 5 || !header.recipient.equals(receiver))
    throw new Error("Message is not addressed to the selected Solana receiver");
  if (
    !header.destinationCaller.equals(PublicKey.default) &&
    !header.destinationCaller.equals(provider.wallet.publicKey)
  )
    throw new Error("Wallet does not match the message destination caller");
  const [usedNonce] = PublicKey.findProgramAddressSync(
    [Buffer.from("used_nonce"), message.subarray(12, 44)],
    messageTransmitterProgram.programId
  );
  const alreadyProcessed = async () =>
    (await messageTransmitterProgram.account.usedNonce.fetchNullable(usedNonce, "confirmed"))?.isUsed === true;
  // Check before reading mutable receiver state: delivery may have changed the remote admin or token mapping.
  if (await alreadyProcessed()) return null;
  const remainingAccounts = await buildAccounts(header);
  const [messageTransmitterState] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter")],
    messageTransmitterProgram.programId
  );
  const [authorityPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("message_transmitter_authority"), receiver.toBuffer()],
    messageTransmitterProgram.programId
  );
  try {
    return await messageTransmitterProgram.methods
      .receiveMessage({ message, attestation })
      .accountsPartial({
        payer: provider.wallet.publicKey,
        caller: provider.wallet.publicKey,
        authorityPda,
        messageTransmitter: messageTransmitterState,
        usedNonce,
        receiver,
        program: messageTransmitterProgram.programId,
      })
      .remainingAccounts(remainingAccounts)
      .rpc({ commitment: "confirmed" });
  } catch (error) {
    if (await alreadyProcessed()) return null;
    throw error;
  }
}

/** Returns null if already delivered, including a race with another finalizer. */
export async function receiveCctpV2MessageOnSpoke(
  provider: AnchorProvider,
  program: ReturnType<typeof getSpokePoolProgram>,
  statePda: PublicKey,
  message: Buffer,
  attestation: Buffer,
  messageTransmitterProgram = getMessageTransmitterV2Program(provider)
): Promise<string | null> {
  return receiveCctpV2Message(
    provider,
    program.programId,
    message,
    attestation,
    messageTransmitterProgram,
    async (header) => {
      if (header.messageBody.length < 4) throw new Error("CCTP V2 spoke message is shorter than its selector");
      if (header.finalityThresholdExecuted < CCTP_FINALITY_THRESHOLD_FINALIZED)
        throw new Error("Spoke messages require finalized attestations");
      const state = await program.account.state.fetch(statePda, "confirmed");
      if (header.sourceDomain !== state.remoteDomain || !header.sender.equals(state.crossDomainAdmin))
        throw new Error("Message does not match the spoke's remote domain and admin");
      const [selfAuthority] = PublicKey.findProgramAddressSync([Buffer.from("self_authority")], program.programId);
      return [
        { pubkey: statePda, isSigner: false, isWritable: false },
        { pubkey: selfAuthority, isSigner: false, isWritable: false },
        { pubkey: program.programId, isSigner: false, isWritable: false },
        ...getCctpV2SpokeAccounts(program.programId, statePda, state, provider.wallet.publicKey, header.messageBody),
      ];
    }
  );
}

export async function receiveCctpV2Tokens(
  provider: AnchorProvider,
  program: ReturnType<typeof getTokenMessengerMinterV2Program>,
  statePda: PublicKey,
  message: Buffer,
  attestation: Buffer,
  expectedTokenRecipient?: PublicKey,
  messageTransmitterProgram = getMessageTransmitterV2Program(provider)
): Promise<string | null> {
  // TokenMessenger supports both finalized and unfinalized delivery and enforces its own finality floor.
  return receiveCctpV2Message(provider, program.programId, message, attestation, messageTransmitterProgram, (header) =>
    getCctpV2TokenAccounts(program, statePda, header, expectedTokenRecipient)
  );
}

/** Optional token support is enabled by the standalone CLI; pause scripts remain spoke-only. */
export async function finalizeCctpV2Messages(
  provider: AnchorProvider,
  program: ReturnType<typeof getSpokePoolProgram>,
  statePda: PublicKey,
  txHash: string,
  sourceDomain: number,
  irisApiUrl: string,
  timeoutMs = 120_000,
  nonce?: string,
  tokens?: { program: ReturnType<typeof getTokenMessengerMinterV2Program>; expectedRecipient?: PublicKey }
): Promise<void> {
  const messages = await fetchCctpV2Messages(txHash, sourceDomain, irisApiUrl, timeoutMs);
  const matching = messages.filter(({ message }) => {
    if (message.length < 148) throw new Error("Invalid CCTP V2 message header");
    const header = decodeMessageHeaderV2(message);
    return (
      header.sourceDomain === sourceDomain &&
      header.destinationDomain === 5 &&
      (header.recipient.equals(program.programId) || (tokens && header.recipient.equals(tokens.program.programId))) &&
      (nonce === undefined || BigInt(header.nonce.toString()) === BigInt(nonce))
    );
  });
  if (!matching.length) throw new Error("No matching CCTP V2 messages addressed to the selected receivers");
  if (matching.length > 1)
    throw new Error(
      `Multiple messages; rerun with --nonce in the intended source order. Nonces: ${matching
        .map(({ message }) => decodeMessageHeaderV2(message).nonce.toString())
        .join(", ")}`
    );
  const { message, attestation } = matching[0];
  const header = decodeMessageHeaderV2(message);
  const signature = header.recipient.equals(program.programId)
    ? await receiveCctpV2MessageOnSpoke(provider, program, statePda, message, attestation)
    : await receiveCctpV2Tokens(provider, tokens!.program, statePda, message, attestation, tokens!.expectedRecipient);
  console.log(`Nonce ${header.nonce}: ${signature ?? "already processed"}`);
}
