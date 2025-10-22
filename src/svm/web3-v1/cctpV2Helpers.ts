import * as anchor from "@coral-xyz/anchor";
import { readUInt256BE } from "./relayHashUtils";

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
