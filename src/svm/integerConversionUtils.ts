/**
 * Converts an integer to a 32-byte Uint8Array.
 */
export function intToU8Array32(num: number): number[] {
  if (!Number.isInteger(num) || num < 0) {
    throw new Error("Input must be a non-negative integer");
  }

  const u8Array = new Array(32).fill(0);
  let i = 0;
  while (num > 0 && i < 32) {
    u8Array[i++] = num & 0xff; // Get least significant byte
    num >>= 8; // Shift right by 8 bits
  }

  return u8Array;
}

/**
 * Converts a 32-byte Uint8Array to a bigint.
 */
export function u8Array32ToInt(u8Array: Uint8Array): bigint {
  if (!(u8Array instanceof Uint8Array) || u8Array.length !== 32) {
    throw new Error("Input must be a Uint8Array of length 32");
  }
  return u8Array.reduce((num, byte, i) => num | (BigInt(byte) << BigInt(i * 8)), 0n);
}
