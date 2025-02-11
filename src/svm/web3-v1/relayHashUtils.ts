import { BN } from "@coral-xyz/anchor";
import { serialize } from "borsh";
import { ethers } from "ethers";
import { RelayerRefundLeaf, RelayerRefundLeafSolana, SlowFillLeaf } from "../../types/svm";

/**
 * Class for V3 relay data.
 */
class V3RelayData {
  constructor(properties: any) {
    Object.assign(this, properties);
  }
}

/**
 * Schema for V3 relay data.
 */
const V3RelayDataSchema = new Map([
  [
    V3RelayData,
    {
      kind: "struct",
      fields: [
        ["depositor", [32]],
        ["recipient", [32]],
        ["exclusiveRelayer", [32]],
        ["inputToken", [32]],
        ["outputToken", [32]],
        ["inputAmount", "u64"],
        ["outputAmount", "u64"],
        ["originChainId", "u64"],
        ["depositId", [32]],
        ["fillDeadline", "u32"],
        ["exclusivityDeadline", "u32"],
        ["message", ["u8"]],
      ],
    },
  ],
]);

/**
 * Calculates the relay hash from relay data and chain ID.
 */
export function calculateRelayHashUint8Array(relayData: any, chainId: BN) {
  const serializedRelayData = Buffer.from(
    serialize(
      V3RelayDataSchema,
      new V3RelayData({
        depositor: relayData.depositor.toBuffer(),
        recipient: relayData.recipient.toBuffer(),
        exclusiveRelayer: relayData.exclusiveRelayer.toBuffer(),
        inputToken: relayData.inputToken.toBuffer(),
        outputToken: relayData.outputToken.toBuffer(),
        inputAmount: relayData.inputAmount,
        outputAmount: relayData.outputAmount,
        originChainId: relayData.originChainId,
        depositId: relayData.depositId,
        fillDeadline: relayData.fillDeadline,
        exclusivityDeadline: relayData.exclusivityDeadline,
        message: relayData.message,
      })
    )
  );

  const contentToHash = Buffer.concat([serializedRelayData, chainId.toArrayLike(Buffer, "le", 8)]);

  const relayHash = ethers.utils.keccak256(contentToHash);
  return Uint8Array.from(Buffer.from(relayHash.slice(2), "hex"));
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
    relayEventData.inputAmount.toArrayLike(Buffer, "le", 8),
    relayEventData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayEventData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(relayEventData.depositId),
    new BN(relayEventData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(relayEventData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    Buffer.from(relayEventData.messageHash), // Renamed to messageHash in the event data.
    chainId.toArrayLike(Buffer, "le", 8),
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
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
    const hash = ethers.utils.keccak256(message);
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

  return ethers.utils.keccak256(contentToHash);
}

/**
 * Hash function for relayer refund leaves.
 */
export const relayerRefundHashFn = (input: RelayerRefundLeaf | RelayerRefundLeafSolana) => {
  if (!input.isSolana) {
    const abiCoder = new ethers.utils.AbiCoder();
    const encodedData = abiCoder.encode(
      [
        "tuple( uint256 amountToReturn, uint256 chainId, uint256[] refundAmounts, uint256 leafId, address l2TokenAddress, address[] refundAddresses)",
      ],
      [
        {
          leafId: input.leafId,
          chainId: input.chainId,
          amountToReturn: input.amountToReturn,
          l2TokenAddress: (input as RelayerRefundLeaf).l2TokenAddress, // Type assertion
          refundAddresses: (input as RelayerRefundLeaf).refundAddresses, // Type assertion
          refundAmounts: (input as RelayerRefundLeaf).refundAmounts, // Type assertion
        },
      ]
    );
    return ethers.utils.keccak256(encodedData);
  } else {
    return calculateRelayerRefundLeafHashUint8Array(input as RelayerRefundLeafSolana);
  }
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
        ["inputAmount", "u64"],
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

  return ethers.utils.keccak256(contentToHash);
}
