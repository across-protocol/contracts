import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";

/**
 * Converts an integer to a 32-byte Uint8Array.
 */
export function intToU8Array32(num: number | BN): number[] {
  let bigIntValue: bigint;

  if (typeof num === "number") {
    if (!Number.isInteger(num) || num < 0) {
      throw new Error("Input must be a non-negative integer");
    }
    bigIntValue = BigInt(num);
  } else if (BN.isBN(num)) {
    if (num.isNeg()) {
      throw new Error("Input must be a non-negative BN");
    }
    bigIntValue = BigInt(num.toString());
  } else {
    throw new Error("Input must be a non-negative integer or BN");
  }

  const u8Array = new Array(32).fill(0);

  // Get the 4-byte BE representation of the number
  const beBytes = Array.from(bigIntValue.toString(16).padStart(8, "0").match(/.{2}/g) || []).map((byte) =>
    parseInt(byte, 16)
  );

  // Insert the BE bytes into the last 4 bytes of the array
  for (let i = 0; i < 4; i++) {
    u8Array[28 + i] = beBytes[i] || 0;
  }

  return u8Array;
}

/**
 * Converts a 32-byte Uint8Array to a bigint.
 */
export function u8Array32ToInt(u8Array: Uint8Array | number[]): bigint {
  const isValidArray = (arr: any): arr is number[] => Array.isArray(arr) && arr.every(Number.isInteger);

  if ((u8Array instanceof Uint8Array || isValidArray(u8Array)) && u8Array.length === 32) {
    return Array.from(u8Array.slice(28, 32)).reduce<bigint>((num, byte) => (num << 8n) | BigInt(byte), 0n);
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
