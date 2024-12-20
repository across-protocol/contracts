import * as anchor from "@coral-xyz/anchor";
import { array, object, optional, string, Struct } from "superstruct";
import { readUInt256BE } from "../../src/svm";

// Index positions to decode Message Header from
// https://developers.circle.com/stablecoins/docs/message-format#message-header
const HEADER_VERSION_INDEX = 0;
const SOURCE_DOMAIN_INDEX = 4;
const DESTINATION_DOMAIN_INDEX = 8;
const NONCE_INDEX = 12;
const HEADER_SENDER_INDEX = 20;
const HEADER_RECIPIENT_INDEX = 52;
const DESTINATION_CALLER_INDEX = 84;
const MESSAGE_BODY_INDEX = 116;

// Index positions to decode Message Body for TokenMessenger from
// https://developers.circle.com/stablecoins/docs/message-format#message-body
const BODY_VERSION_INDEX = 0;
const BURN_TOKEN_INDEX = 4;
const MINT_RECIPIENT_INDEX = 36;
const AMOUNT_INDEX = 68;
const MESSAGE_SENDER_INDEX = 100;

/**
 * Type for the body of a TokenMessenger message.
 */
export type TokenMessengerMessageBody = {
  version: number;
  burnToken: anchor.web3.PublicKey;
  mintRecipient: anchor.web3.PublicKey;
  amount: BigInt;
  messageSender: anchor.web3.PublicKey;
};

/**
 * Type for the header of a CCTP message.
 */
export type MessageHeader = {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  nonce: bigint;
  sender: anchor.web3.PublicKey;
  recipient: anchor.web3.PublicKey;
  destinationCaller: anchor.web3.PublicKey;
  messageBody: Buffer;
};

/**
 * Decodes a CCTP message into a MessageHeader and TokenMessengerMessageBody.
 */
export const decodeMessageSentData = (message: Buffer) => {
  const messageHeader = decodeMessageHeader(message);

  const messageBodyData = message.slice(MESSAGE_BODY_INDEX);

  const messageBody = decodeTokenMessengerMessageBody(messageBodyData);

  return { ...messageHeader, messageBody };
};

/**
 * Decodes a CCTP message header.
 */
export const decodeMessageHeader = (data: Buffer): MessageHeader => {
  const version = data.readUInt32BE(HEADER_VERSION_INDEX);
  const sourceDomain = data.readUInt32BE(SOURCE_DOMAIN_INDEX);
  const destinationDomain = data.readUInt32BE(DESTINATION_DOMAIN_INDEX);
  const nonce = data.readBigUInt64BE(NONCE_INDEX);
  const sender = new anchor.web3.PublicKey(data.slice(HEADER_SENDER_INDEX, HEADER_SENDER_INDEX + 32));
  const recipient = new anchor.web3.PublicKey(data.slice(HEADER_RECIPIENT_INDEX, HEADER_RECIPIENT_INDEX + 32));
  const destinationCaller = new anchor.web3.PublicKey(
    data.slice(DESTINATION_CALLER_INDEX, DESTINATION_CALLER_INDEX + 32)
  );
  const messageBody = data.slice(MESSAGE_BODY_INDEX);
  return {
    version,
    sourceDomain,
    destinationDomain,
    nonce,
    sender,
    recipient,
    destinationCaller,
    messageBody,
  };
};

/**
 * Decodes a TokenMessenger message body.
 */
export const decodeTokenMessengerMessageBody = (data: Buffer): TokenMessengerMessageBody => {
  const version = data.readUInt32BE(BODY_VERSION_INDEX);
  const burnToken = new anchor.web3.PublicKey(data.slice(BURN_TOKEN_INDEX, BURN_TOKEN_INDEX + 32));
  const mintRecipient = new anchor.web3.PublicKey(data.slice(MINT_RECIPIENT_INDEX, MINT_RECIPIENT_INDEX + 32));
  const amount = readUInt256BE(data.slice(AMOUNT_INDEX, AMOUNT_INDEX + 32));
  const messageSender = new anchor.web3.PublicKey(data.slice(MESSAGE_SENDER_INDEX, MESSAGE_SENDER_INDEX + 32));
  return { version, burnToken, mintRecipient, amount, messageSender };
};

/**
 * Encodes a MessageHeader into a Buffer.
 */
export const encodeMessageHeader = (header: MessageHeader): Buffer => {
  const message = Buffer.alloc(MESSAGE_BODY_INDEX + header.messageBody.length);

  message.writeUInt32BE(header.version, HEADER_VERSION_INDEX);
  message.writeUInt32BE(header.sourceDomain, SOURCE_DOMAIN_INDEX);
  message.writeUInt32BE(header.destinationDomain, DESTINATION_DOMAIN_INDEX);
  message.writeBigUInt64BE(header.nonce, NONCE_INDEX);
  header.sender.toBuffer().copy(message, HEADER_SENDER_INDEX);
  header.recipient.toBuffer().copy(message, HEADER_RECIPIENT_INDEX);
  header.destinationCaller.toBuffer().copy(message, DESTINATION_CALLER_INDEX);
  header.messageBody.copy(message, MESSAGE_BODY_INDEX);

  return message;
};

/**
 * Type for the attestation response from the attestation service.
 */
type AttestationResponse = {
  error?: string;
  messages: {
    attestation: string;
    message: string;
    eventNonce: string;
  }[];
};

/**
 * Structure for the attestation response from the attestation service.
 */
const AttestationResponseStruct: Struct<AttestationResponse, any> = object({
  error: optional(string()),
  messages: array(
    object({
      attestation: string(),
      message: string(),
      eventNonce: string(),
    })
  ),
});

/**
 * Fetches attestation from attestation service given the txHash.
 */
export const getMessages = async (
  txHash: string,
  srcDomain: number,
  irisApiUrl: string
): Promise<AttestationResponse> => {
  console.log("Fetching attestations and messages for tx...", txHash);
  let attestationResponse: any = {};
  while (
    attestationResponse.error ||
    !attestationResponse.messages ||
    attestationResponse.messages?.[0]?.attestation === "PENDING"
  ) {
    const response = await fetch(`${irisApiUrl}/messages/${srcDomain}/${txHash}`);
    attestationResponse = await response.json();

    // Validate the response structure
    try {
      AttestationResponseStruct.assert(attestationResponse);
    } catch (error) {
      console.error("Invalid attestation response structure:", error);
      throw new Error("Invalid attestation response structure");
    }

    // Wait 2 seconds to avoid getting rate limited
    if (
      attestationResponse.error ||
      !attestationResponse.messages ||
      attestationResponse.messages?.[0]?.attestation === "PENDING"
    ) {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  return attestationResponse;
};
