import * as anchor from "@coral-xyz/anchor";
import { array, enums, object, optional, string, union, nullable, Infer, coerce } from "superstruct";
import { ethers } from "ethers";
import { assert } from "superstruct";
import { readUInt256BE } from "./relayHashUtils";
import { addressOrBase58ToBytes32 } from "./conversionUtils";

// Index positions to decode Message Header from
// https://developers.circle.com/cctp/technical-guide#message-header
const HEADER_VERSION_INDEX = 0;
const SOURCE_DOMAIN_INDEX = 4;
const DESTINATION_DOMAIN_INDEX = 8;
const NONCE_INDEX = 12;
const HEADER_SENDER_INDEX = 44;
const HEADER_RECIPIENT_INDEX = 76;
const DESTINATION_CALLER_INDEX = 108;
const MIN_FINALITY_THRESHOLD_INDEX = 140;
const FINALITY_THRESHOLD_EXECUTED_INDEX = 144;
const MESSAGE_BODY_INDEX = 148;

// Index positions to decode Message Body for TokenMessengerV2 from
// https://developers.circle.com/cctp/technical-guide#message-body
const BODY_VERSION_INDEX = 0;
const BURN_TOKEN_INDEX = 4;
const MINT_RECIPIENT_INDEX = 36;
const AMOUNT_INDEX = 68;
const MESSAGE_SENDER_INDEX = 100;
const MAX_FEE_INDEX = 132;
const FEE_EXECUTED_INDEX = 164;
const EXPIRATION_BLOCK = 196;
const HOOK_DATA_INDEX = 228;

export const EVENT_ACCOUNT_WINDOW_SECONDS = 60 * 60 * 24 * 5; // 60 secs * 60 mins * 24 hours * 5 days = 5 days in seconds

/**
 * Type for the body of a TokenMessengerV2 message.
 */
export type TokenMessengerV2MessageBody = {
  version: number;
  burnToken: anchor.web3.PublicKey;
  mintRecipient: anchor.web3.PublicKey;
  amount: BigInt;
  messageSender: anchor.web3.PublicKey;
  maxFee: BigInt;
  feeExecuted: BigInt;
  expirationBlock: BigInt;
  hookData: Buffer;
};

/**
 * Type for the header of a CCTPv2 message.
 */
export type MessageHeaderV2 = {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  nonce: BigInt;
  sender: anchor.web3.PublicKey;
  recipient: anchor.web3.PublicKey;
  destinationCaller: anchor.web3.PublicKey;
  minFinalityThreshold: number;
  finalityThresholdExecuted: number;
  messageBody: Buffer;
};

/**
 * Decodes a CCTPv2 message into a MessageHeaderV2 and TokenMessengerV2MessageBody.
 */
export const decodeMessageSentDataV2 = (message: Buffer) => {
  const messageHeader = decodeMessageHeaderV2(message);

  const messageBodyData = message.slice(MESSAGE_BODY_INDEX);

  const messageBody = decodeTokenMessengerV2MessageBody(messageBodyData);

  return { ...messageHeader, messageBody };
};

/**
 * Decodes a CCTPv2 message header.
 */
export const decodeMessageHeaderV2 = (data: Buffer): MessageHeaderV2 => {
  const version = data.readUInt32BE(HEADER_VERSION_INDEX);
  const sourceDomain = data.readUInt32BE(SOURCE_DOMAIN_INDEX);
  const destinationDomain = data.readUInt32BE(DESTINATION_DOMAIN_INDEX);
  const nonce = readUInt256BE(data.slice(NONCE_INDEX, NONCE_INDEX + 32));
  const sender = new anchor.web3.PublicKey(data.slice(HEADER_SENDER_INDEX, HEADER_SENDER_INDEX + 32));
  const recipient = new anchor.web3.PublicKey(data.slice(HEADER_RECIPIENT_INDEX, HEADER_RECIPIENT_INDEX + 32));
  const destinationCaller = new anchor.web3.PublicKey(
    data.slice(DESTINATION_CALLER_INDEX, DESTINATION_CALLER_INDEX + 32)
  );
  const minFinalityThreshold = data.readUInt32BE(MIN_FINALITY_THRESHOLD_INDEX);
  const finalityThresholdExecuted = data.readUInt32BE(FINALITY_THRESHOLD_EXECUTED_INDEX);
  const messageBody = data.slice(MESSAGE_BODY_INDEX);
  return {
    version,
    sourceDomain,
    destinationDomain,
    nonce,
    sender,
    recipient,
    destinationCaller,
    minFinalityThreshold,
    finalityThresholdExecuted,
    messageBody,
  };
};

/**
 * Decodes a TokenMessenger message body.
 */
export const decodeTokenMessengerV2MessageBody = (data: Buffer): TokenMessengerV2MessageBody => {
  const version = data.readUInt32BE(BODY_VERSION_INDEX);
  const burnToken = new anchor.web3.PublicKey(data.slice(BURN_TOKEN_INDEX, BURN_TOKEN_INDEX + 32));
  const mintRecipient = new anchor.web3.PublicKey(data.slice(MINT_RECIPIENT_INDEX, MINT_RECIPIENT_INDEX + 32));
  const amount = readUInt256BE(data.slice(AMOUNT_INDEX, AMOUNT_INDEX + 32));
  const messageSender = new anchor.web3.PublicKey(data.slice(MESSAGE_SENDER_INDEX, MESSAGE_SENDER_INDEX + 32));
  const maxFee = readUInt256BE(data.slice(MAX_FEE_INDEX, MAX_FEE_INDEX + 32));
  const feeExecuted = readUInt256BE(data.slice(FEE_EXECUTED_INDEX, FEE_EXECUTED_INDEX + 32));
  const expirationBlock = readUInt256BE(data.slice(EXPIRATION_BLOCK, EXPIRATION_BLOCK + 32));
  const hookData = data.slice(HOOK_DATA_INDEX);
  return { version, burnToken, mintRecipient, amount, messageSender, maxFee, feeExecuted, expirationBlock, hookData };
};

// Below structs defines the types for CCTP attestation API as documented in
// https://developers.circle.com/api-reference/cctp/all/get-messages-v-2

// DecodedMessage.decodedMessageBody (V1/V2; some fields V2-only)
export const DecodedMessageBody = object({
  burnToken: string(),
  mintRecipient: string(),
  amount: string(),
  messageSender: string(),
  // V2-only
  maxFee: optional(string()),
  feeExecuted: optional(string()),
  expirationBlock: optional(string()),
  hookData: optional(string()),
});

// DecodedMessage (nullable/empty if decoding fails)
// minFinalityThreshold & finalityThresholdExecuted are V2-only
export const DecodedMessage = object({
  sourceDomain: string(),
  destinationDomain: string(),
  nonce: string(),
  sender: string(),
  recipient: string(),
  destinationCaller: string(),
  minFinalityThreshold: optional(enums(["1000", "2000"])),
  finalityThresholdExecuted: optional(enums(["1000", "2000"])),
  messageBody: string(),
  decodedMessageBody: optional(
    coerce(nullable(DecodedMessageBody), union([nullable(DecodedMessageBody), object({})]), (v) =>
      isEmptyObject(v) ? null : v
    )
  ),
});

// Each message item
export const AttestationMessage = object({
  message: string(), // "0x" when not available
  eventNonce: string(),
  attestation: string(), // "PENDING" when not available
  decodedMessage: optional(
    coerce(nullable(DecodedMessage), union([nullable(DecodedMessage), object({})]), (v) =>
      isEmptyObject(v) ? null : v
    )
  ),
  cctpVersion: enums([1, 2]),
  status: enums(["complete", "pending_confirmations"]),
  // Only present in some delayed cases
  delayReason: optional(nullable(enums(["insufficient_fee", "amount_above_max", "insufficient_allowance_available"]))),
});

// Top-level 200 response
export const AttestationResponse = object({
  messages: array(AttestationMessage),
});

export type TAttestationResponse = Infer<typeof AttestationResponse>;
export type TAttestationMessage = Infer<typeof AttestationMessage>;
export type TDecodedMessage = Infer<typeof DecodedMessage>;
export type TDecodedMessageBody = Infer<typeof DecodedMessageBody>;

const isEmptyObject = (v: unknown) =>
  v != null && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 0;

/**
 * Fetches attestation from attestation service given the txHash and source message for CCTP V2 token burn.
 */
export async function getV2BurnAttestation(
  txSignature: string,
  sourceMessageData: Buffer,
  irisApiUrl: string
): Promise<{ destinationMessage: Buffer; attestation: Buffer } | null> {
  const sourceMessage = decodeMessageSentDataV2(sourceMessageData);

  const attestationResponse = await (
    await fetch(`${irisApiUrl}/v2/messages/${sourceMessage.sourceDomain}/?transactionHash=${txSignature}`)
  ).json();
  if (attestationResponse.error) return null;
  assert(attestationResponse, AttestationResponse);

  // Return the first attested message that matches the source message.
  for (const message of attestationResponse.messages) {
    if (
      message.message !== "0x" &&
      message.attestation !== "PENDING" &&
      !!message.decodedMessage &&
      isMatchingV2BurnMessage(sourceMessage, message.decodedMessage)
    ) {
      return {
        destinationMessage: Buffer.from(ethers.utils.arrayify(message.message)),
        attestation: Buffer.from(ethers.utils.arrayify(message.attestation)),
      };
    }
  }
  return null;
}

function isMatchingV2BurnMessage(
  sourceMessage: ReturnType<typeof decodeMessageSentDataV2>,
  destinationMessage: TDecodedMessage
): boolean {
  if (!destinationMessage.decodedMessageBody) return false;

  return (
    sourceMessage.sourceDomain.toString() === destinationMessage.sourceDomain &&
    sourceMessage.destinationDomain.toString() === destinationMessage.destinationDomain &&
    // nonce is only set on destination
    addressOrBase58ToBytes32(sourceMessage.sender.toString()) === addressOrBase58ToBytes32(destinationMessage.sender) &&
    addressOrBase58ToBytes32(sourceMessage.recipient.toString()) ===
      addressOrBase58ToBytes32(destinationMessage.recipient) &&
    addressOrBase58ToBytes32(sourceMessage.destinationCaller.toString()) ===
      addressOrBase58ToBytes32(destinationMessage.destinationCaller) &&
    sourceMessage.minFinalityThreshold.toString() === destinationMessage.minFinalityThreshold &&
    // finalityThresholdExecuted is only set on destination
    addressOrBase58ToBytes32(sourceMessage.messageBody.burnToken.toString()) ===
      addressOrBase58ToBytes32(destinationMessage.decodedMessageBody.burnToken) &&
    addressOrBase58ToBytes32(sourceMessage.messageBody.mintRecipient.toString()) ===
      addressOrBase58ToBytes32(destinationMessage.decodedMessageBody.mintRecipient) &&
    sourceMessage.messageBody.amount.toString() === destinationMessage.decodedMessageBody.amount &&
    addressOrBase58ToBytes32(sourceMessage.messageBody.messageSender.toString()) ===
      addressOrBase58ToBytes32(destinationMessage.decodedMessageBody.messageSender) &&
    sourceMessage.messageBody.maxFee.toString() === destinationMessage.decodedMessageBody.maxFee &&
    // feeExecuted is only set on destination
    // expirationBlock is only set on destination
    sourceMessage.messageBody.hookData.equals(
      Buffer.from(ethers.utils.arrayify(destinationMessage.decodedMessageBody.hookData || "0x"))
    )
  );
}
