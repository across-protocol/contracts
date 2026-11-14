import { utils as anchorUtils, BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { keccak_256 } from "@noble/hashes/sha3";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils";

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
 * Converts a 0x-prefixed, even-length hex string to bytes. Throws on malformed input.
 */
export function hexToBytesStrict(hex: string): Uint8Array {
  if (!/^0x([0-9a-fA-F]{2})*$/.test(hex)) throw new Error(`Invalid hex string: ${hex}`);
  return Buffer.from(hex.slice(2), "hex");
}

/**
 * Returns true for a 0x-prefixed 20-byte hex address. Mixed-case input must carry a valid EIP-55 checksum.
 */
export function isEvmAddress(address: string): boolean {
  if (!/^0x[0-9a-fA-F]{40}$/.test(address)) return false;
  const hex = address.slice(2);
  if (hex === hex.toLowerCase() || hex === hex.toUpperCase()) return true;
  const hash = bytesToHex(keccak_256(utf8ToBytes(hex.toLowerCase())));
  return [...hex].every((c, i) => c === (parseInt(hash[i], 16) >= 8 ? c.toUpperCase() : c.toLowerCase()));
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
  return new PublicKey(hexToBytesStrict(bytes32Address));
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

/**
 * Converts EVM or SVM address to a bytes32 string.
 */
export const addressOrBase58ToBytes32 = (input: string): string => {
  if (isEvmAddress(input)) {
    return "0x" + input.slice(2).padStart(64, "0");
  } else if (/^0x[0-9a-fA-F]{64}$/.test(input)) {
    return input;
  } else {
    return fromBase58ToBytes32(input);
  }
};
