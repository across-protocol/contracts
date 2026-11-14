import { BN } from "@coral-xyz/anchor";
import { keccak_256 } from "@noble/hashes/sha3";
import { bytesToHex } from "@noble/hashes/utils";
import { RelayerRefundLeafSolana, RelayerRefundLeafType, SlowFillLeaf } from "../../types/svm";
import { serialize } from "borsh";
import { isEvmAddress } from "./conversionUtils";

const keccak256 = (data: Uint8Array): string => "0x" + bytesToHex(keccak_256(data));

/**
 * Calculates the relay hash from relay data and chain ID.
 */
export function calculateRelayHashUint8Array(relayData: any, chainId: BN): Uint8Array {
  const contentToHash = Buffer.concat([
    relayData.depositor.toBuffer(),
    relayData.recipient.toBuffer(),
    relayData.exclusiveRelayer.toBuffer(),
    relayData.inputToken.toBuffer(),
    relayData.outputToken.toBuffer(),
    Buffer.from(relayData.inputAmount),
    relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(relayData.depositId),
    new BN(relayData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(relayData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    hashNonEmptyMessage(relayData.message), // Replace with hash of message, so that relay hash can be recovered from event.
    chainId.toArrayLike(Buffer, "le", 8),
  ]);

  const relayHash = keccak256(contentToHash);
  const relayHashBuffer = Buffer.from(relayHash.slice(2), "hex");
  return new Uint8Array(relayHashBuffer);
}

/**
 * Calculates the relay event hash from relay event data and chain ID.
 */
export function calculateRelayEventHashUint8Array(relayEventData: any, chainId: BN): Uint8Array {
  const contentToHash = Buffer.concat([
    relayEventData.depositor.toBuffer(),
    relayEventData.recipient.toBuffer(),
    relayEventData.exclusiveRelayer.toBuffer(),
    relayEventData.inputToken.toBuffer(),
    relayEventData.outputToken.toBuffer(),
    Buffer.from(relayEventData.inputAmount),
    relayEventData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayEventData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(relayEventData.depositId),
    new BN(relayEventData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(relayEventData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    Buffer.from(relayEventData.messageHash), // Renamed to messageHash in the event data.
    chainId.toArrayLike(Buffer, "le", 8),
  ]);

  const relayHash = keccak256(contentToHash);
  const relayHashBuffer = Buffer.from(relayHash.slice(2), "hex");
  return new Uint8Array(relayHashBuffer);
}

/**
 * Reads a 256-bit unsigned integer from a buffer.
 */
export const readUInt256BE = (buffer: Buffer): BigInt => {
  let result = BigInt(0);
  for (let i = 0; i < buffer.length; i++) {
    result = (result << BigInt(8)) + BigInt(buffer[i]);
  }
  return result;
};

/**
 * Hashes a non-empty message using Keccak256.
 */
export function hashNonEmptyMessage(message: Buffer) {
  if (message.length > 0) {
    const hash = keccak256(message);
    return Uint8Array.from(Buffer.from(hash.slice(2), "hex"));
  }
  // else return zeroed bytes32
  return new Uint8Array(32);
}

/**
 * Class for relay data.
 */
class RelayData {
  constructor(properties: any) {
    Object.assign(this, properties);
  }
}

/**
 * Schema for relay data.
 */
const relayDataSchema = new Map([
  [
    RelayData,
    {
      kind: "struct",
      fields: [
        ["amountToReturn", "u64"],
        ["chainId", "u64"],
        ["refundAmounts", ["u64"]],
        ["leafId", "u32"],
        ["mintPublicKey", [32]],
        ["refundAddresses", [[32]]],
      ],
    },
  ],
]);

/**
 * Calculates the relayer refund leaf hash for Solana.
 */
export function calculateRelayerRefundLeafHashUint8Array(relayData: RelayerRefundLeafSolana): string {
  const refundAddresses = relayData.refundAddresses.map((address) => address.toBuffer());

  const data = new RelayData({
    amountToReturn: relayData.amountToReturn,
    chainId: relayData.chainId,
    refundAmounts: relayData.refundAmounts,
    leafId: relayData.leafId,
    mintPublicKey: relayData.mintPublicKey.toBuffer(),
    refundAddresses: refundAddresses,
  });

  const serializedData = serialize(relayDataSchema, data);

  // SVM leaves require the first 64 bytes to be 0 to ensure EVM leaves can never be played on SVM and vice versa.
  const contentToHash = Buffer.concat([Buffer.alloc(64, 0), serializedData]);

  return keccak256(contentToHash);
}

const uint256Word = (value: bigint): string => {
  if (value < 0n || value >= 2n ** 256n) throw new Error(`Invalid uint256: ${value}`);
  return value.toString(16).padStart(64, "0");
};

const addressWord = (address: string): string => {
  if (!isEvmAddress(address)) throw new Error(`Invalid EVM address: ${address}`);
  return address.slice(2).toLowerCase().padStart(64, "0");
};

/**
 * Hash function for relayer refund leaves. EVM leaves are ABI-encoded as a single
 * tuple(uint256 amountToReturn, uint256 chainId, uint256[] refundAmounts, uint256 leafId, address l2TokenAddress, address[] refundAddresses).
 */
export const relayerRefundHashFn = (input: RelayerRefundLeafType) => {
  if (input.isSolana) return calculateRelayerRefundLeafHashUint8Array(input);

  const { amountToReturn, chainId, refundAmounts, leafId, l2TokenAddress, refundAddresses } = input;
  const headSize = 6n * 32n;
  const encodedData = [
    uint256Word(32n), // Offset to the tuple, which is dynamic.
    uint256Word(amountToReturn),
    uint256Word(chainId),
    uint256Word(headSize), // Offset to refundAmounts, relative to the tuple.
    uint256Word(leafId),
    addressWord(l2TokenAddress),
    uint256Word(headSize + 32n * BigInt(refundAmounts.length + 1)), // Offset to refundAddresses.
    uint256Word(BigInt(refundAmounts.length)),
    ...refundAmounts.map(uint256Word),
    uint256Word(BigInt(refundAddresses.length)),
    ...refundAddresses.map(addressWord),
  ].join("");
  return keccak256(Buffer.from(encodedData, "hex"));
};

/**
 * Class for slow fill data.
 */
class SlowFillData {
  constructor(properties: any) {
    Object.assign(this, properties);
  }
}

/**
 * Schema for slow fill data.
 */
const slowFillDataSchema = new Map([
  [
    SlowFillData,
    {
      kind: "struct",
      fields: [
        ["depositor", [32]],
        ["recipient", [32]],
        ["exclusiveRelayer", [32]],
        ["inputToken", [32]],
        ["outputToken", [32]],
        ["inputAmount", [32]],
        ["outputAmount", "u64"],
        ["originChainId", "u64"],
        ["depositId", [32]],
        ["fillDeadline", "u32"],
        ["exclusivityDeadline", "u32"],
        ["message", ["u8"]],
        ["chainId", "u64"],
        ["updatedOutputAmount", "u64"],
      ],
    },
  ],
]);

/**
 * Hash function for slow fill leaves.
 */
export function slowFillHashFn(slowFillLeaf: SlowFillLeaf): string {
  const data = new SlowFillData({
    depositor: Uint8Array.from(slowFillLeaf.relayData.depositor.toBuffer()),
    recipient: Uint8Array.from(slowFillLeaf.relayData.recipient.toBuffer()),
    exclusiveRelayer: Uint8Array.from(slowFillLeaf.relayData.exclusiveRelayer.toBuffer()),
    inputToken: Uint8Array.from(slowFillLeaf.relayData.inputToken.toBuffer()),
    outputToken: Uint8Array.from(slowFillLeaf.relayData.outputToken.toBuffer()),
    inputAmount: slowFillLeaf.relayData.inputAmount,
    outputAmount: slowFillLeaf.relayData.outputAmount,
    originChainId: slowFillLeaf.relayData.originChainId,
    depositId: Uint8Array.from(Buffer.from(slowFillLeaf.relayData.depositId)),
    fillDeadline: slowFillLeaf.relayData.fillDeadline,
    exclusivityDeadline: slowFillLeaf.relayData.exclusivityDeadline,
    message: Uint8Array.from(slowFillLeaf.relayData.message),
    chainId: slowFillLeaf.chainId,
    updatedOutputAmount: slowFillLeaf.updatedOutputAmount,
  });

  const serializedData = serialize(slowFillDataSchema, data);

  // SVM leaves require the first 64 bytes to be 0 to ensure EVM leaves cannot be played on SVM and vice versa
  const contentToHash = Buffer.concat([Buffer.alloc(64, 0), serializedData]);

  return keccak256(contentToHash);
}
