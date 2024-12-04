import { utils as anchorUtils } from "@coral-xyz/anchor";

export const fromBase58ToBytes32 = (input: string): string => {
  const decodedBytes = anchorUtils.bytes.bs58.decode(input);
  return "0x" + Buffer.from(decodedBytes).toString("hex");
};

export const fromBytes32ToAddress = (input: string): string => {
  // Remove the '0x' prefix if present
  const hexString = input.startsWith("0x") ? input.slice(2) : input;

  // Ensure the input is 64 characters long (32 bytes)
  if (hexString.length !== 64) {
    throw new Error("Invalid bytes32 string");
  }

  // Get the last 40 characters (20 bytes) for the address
  const address = hexString.slice(-40);

  return "0x" + address;
};
