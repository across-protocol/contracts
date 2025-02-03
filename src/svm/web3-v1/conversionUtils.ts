import { utils as anchorUtils, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { BigNumber, ethers } from "ethers";

/**
 * Converts an integer to a 32-byte Uint8Array.
 */
export function intToU8Array32(num: number | BN): number[] {
  const bigIntValue = BigInt(num instanceof BN ? num.toString() : num);
  if (bigIntValue < 0) throw new Error("Input must be a non-negative integer or BN");

  const hexString = bigIntValue.toString(16).padStart(64, "0"); // 32 bytes = 64 hex chars
  const u8Array = Array.from(Buffer.from(hexString, "hex"));

  return u8Array;
}

/**
 * Converts a 32-byte Uint8Array to a bigint.
 */
export function u8Array32ToInt(u8Array: Uint8Array | number[]): bigint {
  const isValidArray = (arr: any): arr is number[] => Array.isArray(arr) && arr.every(Number.isInteger);

  if ((u8Array instanceof Uint8Array || isValidArray(u8Array)) && u8Array.length === 32) {
    return Array.from(u8Array).reduce<bigint>((num, byte) => (num << 8n) | BigInt(byte), 0n);
  }

  throw new Error("Input must be a Uint8Array or an array of 32 numbers.");
}

/**
 * Converts a 32-byte Uint8Array to a BigNumber.
 */
export function u8Array32ToBigNumber(u8Array: Uint8Array | number[]): BigNumber {
  const isValidArray = (arr: any): arr is number[] => Array.isArray(arr) && arr.every(Number.isInteger);
  if ((u8Array instanceof Uint8Array || isValidArray(u8Array)) && u8Array.length === 32) {
    const hexString = "0x" + Buffer.from(u8Array).toString("hex");
    return BigNumber.from(hexString);
  }

  throw new Error("Input must be a Uint8Array or an array of 32 numbers.");
}

/**
 * Converts a string to a PublicKey.
 */
export function strPublicKey(publicKey: PublicKey): string {
  return new PublicKey(publicKey).toString();
}

/**
 * Converts an EVM address to a Solana PublicKey.
 */
export const evmAddressToPublicKey = (address: string): PublicKey => {
  const bytes32Address = `0x000000000000000000000000${address.replace("0x", "")}`;
  return new PublicKey(ethers.utils.arrayify(bytes32Address));
};

/**
 * Converts a Solana PublicKey to an EVM address.
 */
export const publicKeyToEvmAddress = (publicKey: PublicKey | string): string => {
  // Convert the input to a PublicKey if it's a string
  const pubKeyBuffer = typeof publicKey === "string" ? new PublicKey(publicKey).toBuffer() : publicKey.toBuffer();

  // Extract the last 20 bytes to get the Ethereum address
  const addressBuffer = pubKeyBuffer.slice(-20);

  // Convert the buffer to a hex string and prepend '0x'
  return `0x${addressBuffer.toString("hex")}`;
};

/**
 * Converts a base58 string to a bytes32 string.
 */
export const fromBase58ToBytes32 = (input: string): string => {
  const decodedBytes = anchorUtils.bytes.bs58.decode(input);
  return "0x" + Buffer.from(decodedBytes).toString("hex");
};

/**
 * Converts a bytes32 string to an EVM address.
 */
export const fromBytes32ToAddress = (input: string): string => {
  const hexString = input.startsWith("0x") ? input.slice(2) : input;

  if (hexString.length !== 64) {
    throw new Error("Invalid bytes32 string");
  }

  const address = hexString.slice(-40);

  return "0x" + address;
};
