import { BN } from "@coral-xyz/anchor";
import { ethers } from "ethers";
import { RelayerRefundLeaf, RelayerRefundLeafSolana, SlowFillLeaf } from "../types/svm";

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
    relayData.inputAmount.toArrayLike(Buffer, "le", 8),
    relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    relayData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(relayData.depositId),
    new BN(relayData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(relayData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    hashNonEmptyMessage(relayData.message), // Replace with hash of message, so that relay hash can be recovered from event.
    chainId.toArrayLike(Buffer, "le", 8),
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
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
 * Calculates the relayer refund leaf hash for Solana.
 */
export function calculateRelayerRefundLeafHashUint8Array(relayData: RelayerRefundLeafSolana): string {
  const refundAmountsBuffer = Buffer.concat(
    relayData.refundAmounts.map((amount) => {
      const buf = Buffer.alloc(8);
      amount.toArrayLike(Buffer, "le", 8).copy(buf);
      return buf;
    })
  );

  const refundAddressesBuffer = Buffer.concat(relayData.refundAddresses.map((address) => address.toBuffer()));

  // TODO: We better consider reusing Borch serializer in production.
  const contentToHash = Buffer.concat([
    // SVM leaves require the first 64 bytes to be 0 to ensure EVM leaves can never be played on SVM and vice versa.
    Buffer.alloc(64, 0),
    relayData.amountToReturn.toArrayLike(Buffer, "le", 8),
    relayData.chainId.toArrayLike(Buffer, "le", 8),
    new BN(relayData.refundAmounts.length).toArrayLike(Buffer, "le", 4),
    refundAmountsBuffer,
    relayData.leafId.toArrayLike(Buffer, "le", 4),
    relayData.mintPublicKey.toBuffer(),
    new BN(relayData.refundAddresses.length).toArrayLike(Buffer, "le", 4),
    refundAddressesBuffer,
  ]);

  const relayHash = ethers.utils.keccak256(contentToHash);
  return relayHash;
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
 * Hash function for slow fill leaves.
 */
// TODO: We better consider reusing Borch serializer in production.
export function slowFillHashFn(slowFillLeaf: SlowFillLeaf): string {
  const contentToHash = Buffer.concat([
    // SVM leaves require the first 64 bytes to be 0 to ensure EVM leaves can never be played on SVM and vice versa.
    Buffer.alloc(64, 0),
    slowFillLeaf.relayData.depositor.toBuffer(),
    slowFillLeaf.relayData.recipient.toBuffer(),
    slowFillLeaf.relayData.exclusiveRelayer.toBuffer(),
    slowFillLeaf.relayData.inputToken.toBuffer(),
    slowFillLeaf.relayData.outputToken.toBuffer(),
    slowFillLeaf.relayData.inputAmount.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.outputAmount.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.relayData.originChainId.toArrayLike(Buffer, "le", 8),
    Buffer.from(slowFillLeaf.relayData.depositId),
    new BN(slowFillLeaf.relayData.fillDeadline).toArrayLike(Buffer, "le", 4),
    new BN(slowFillLeaf.relayData.exclusivityDeadline).toArrayLike(Buffer, "le", 4),
    new BN(slowFillLeaf.relayData.message.length).toArrayLike(Buffer, "le", 4),
    slowFillLeaf.relayData.message,
    slowFillLeaf.chainId.toArrayLike(Buffer, "le", 8),
    slowFillLeaf.updatedOutputAmount.toArrayLike(Buffer, "le", 8),
  ]);

  const slowFillHash = ethers.utils.keccak256(contentToHash);
  return slowFillHash;
}
