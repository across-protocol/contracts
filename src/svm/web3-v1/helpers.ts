import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { BigNumber } from "@ethersproject/bignumber";
import { ethers } from "ethers";
import { DepositData } from "../../types/svm";
import { PublicKey } from "@solana/web3.js";
import { serialize } from "borsh";
import { keccak256 } from "ethers/lib/utils";

/**
 * Returns the chainId for a given solana cluster.
 */
export const getSolanaChainId = (cluster: "devnet" | "mainnet"): BigNumber => {
  return BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${cluster}`))) & BigInt("0xFFFFFFFFFFFF")
  );
};

/**
 * Returns true if the provider is on the devnet cluster.
 */
export const isSolanaDevnet = (provider: AnchorProvider): boolean => {
  const solanaRpcEndpoint = provider.connection.rpcEndpoint;
  if (solanaRpcEndpoint.includes("devnet")) return true;
  else if (solanaRpcEndpoint.includes("mainnet")) return false;
  else throw new Error(`Unsupported solanaCluster endpoint: ${solanaRpcEndpoint}`);
};

/**
 * Generic helper: serialize + keccak256 → 32‑byte Uint8Array
 */
function deriveSeedHash<T>(schema: Map<any, any>, seedObj: T): Uint8Array {
  const serialized = serialize(schema, seedObj);
  const hashHex = keccak256(serialized);
  return Buffer.from(hashHex.slice(2), "hex");
}

/**
 * “Absolute‐deadline” deposit data
 */
export class DepositSeedData {
  depositor!: Uint8Array;
  recipient!: Uint8Array;
  inputToken!: Uint8Array;
  outputToken!: Uint8Array;
  inputAmount!: BN;
  outputAmount!: number[];
  destinationChainId!: BN;
  exclusiveRelayer!: Uint8Array;
  quoteTimestamp!: BN;
  fillDeadline!: BN;
  exclusivityParameter!: BN;
  message!: Uint8Array;

  constructor(fields: {
    depositor: Uint8Array;
    recipient: Uint8Array;
    inputToken: Uint8Array;
    outputToken: Uint8Array;
    inputAmount: BN;
    outputAmount: number[];
    destinationChainId: BN;
    exclusiveRelayer: Uint8Array;
    quoteTimestamp: BN;
    fillDeadline: BN;
    exclusivityParameter: BN;
    message: Uint8Array;
  }) {
    Object.assign(this, fields);
  }
}

const depositSeedSchema = new Map([
  [
    DepositSeedData,
    {
      kind: "struct",
      fields: [
        ["depositor", [32]],
        ["recipient", [32]],
        ["inputToken", [32]],
        ["outputToken", [32]],
        ["inputAmount", "u64"],
        ["outputAmount", [32]],
        ["destinationChainId", "u64"],
        ["exclusiveRelayer", [32]],
        ["quoteTimestamp", "u32"],
        ["fillDeadline", "u32"],
        ["exclusivityParameter", "u32"],
        ["message", ["u8"]],
      ],
    },
  ],
]);

/**
 * Hash for the standard `deposit(...)` flow
 */
export function getDepositSeedHash(depositData: {
  depositor: PublicKey;
  recipient: PublicKey;
  inputToken: PublicKey;
  outputToken: PublicKey;
  inputAmount: BN;
  outputAmount: number[];
  destinationChainId: BN;
  exclusiveRelayer: PublicKey;
  quoteTimestamp: BN;
  fillDeadline: BN;
  exclusivityParameter: BN;
  message: Uint8Array;
}): Uint8Array {
  const ds = new DepositSeedData({
    depositor: depositData.depositor.toBuffer(),
    recipient: depositData.recipient.toBuffer(),
    inputToken: depositData.inputToken.toBuffer(),
    outputToken: depositData.outputToken.toBuffer(),
    inputAmount: depositData.inputAmount,
    outputAmount: depositData.outputAmount,
    destinationChainId: depositData.destinationChainId,
    exclusiveRelayer: depositData.exclusiveRelayer.toBuffer(),
    quoteTimestamp: depositData.quoteTimestamp,
    fillDeadline: depositData.fillDeadline,
    exclusivityParameter: depositData.exclusivityParameter,
    message: depositData.message,
  });

  return deriveSeedHash(depositSeedSchema, ds);
}

/**
 * Returns the delegate PDA for `deposit(...)`
 */
export function getDepositPda(depositData: Parameters<typeof getDepositSeedHash>[0], programId: PublicKey): PublicKey {
  const seedHash = getDepositSeedHash(depositData);
  const [pda] = PublicKey.findProgramAddressSync([Buffer.from("delegate"), seedHash], programId);
  return pda;
}

/**
 * “Offset/now” deposit data
 */
export class DepositNowSeedData {
  depositor!: Uint8Array;
  recipient!: Uint8Array;
  inputToken!: Uint8Array;
  outputToken!: Uint8Array;
  inputAmount!: BN;
  outputAmount!: number[];
  destinationChainId!: BN;
  exclusiveRelayer!: Uint8Array;
  fillDeadlineOffset!: BN;
  exclusivityPeriod!: BN;
  message!: Uint8Array;

  constructor(fields: {
    depositor: Uint8Array;
    recipient: Uint8Array;
    inputToken: Uint8Array;
    outputToken: Uint8Array;
    inputAmount: BN;
    outputAmount: number[];
    destinationChainId: BN;
    exclusiveRelayer: Uint8Array;
    fillDeadlineOffset: BN;
    exclusivityPeriod: BN;
    message: Uint8Array;
  }) {
    Object.assign(this, fields);
  }
}

const depositNowSeedSchema = new Map([
  [
    DepositNowSeedData,
    {
      kind: "struct",
      fields: [
        ["depositor", [32]],
        ["recipient", [32]],
        ["inputToken", [32]],
        ["outputToken", [32]],
        ["inputAmount", "u64"],
        ["outputAmount", [32]],
        ["destinationChainId", "u64"],
        ["exclusiveRelayer", [32]],
        ["fillDeadlineOffset", "u32"],
        ["exclusivityPeriod", "u32"],
        ["message", ["u8"]],
      ],
    },
  ],
]);

/**
 * Hash for the `deposit_now(...)` flow
 */
export function getDepositNowSeedHash(depositData: {
  depositor: PublicKey;
  recipient: PublicKey;
  inputToken: PublicKey;
  outputToken: PublicKey;
  inputAmount: BN;
  outputAmount: number[];
  destinationChainId: BN;
  exclusiveRelayer: PublicKey;
  fillDeadlineOffset: BN;
  exclusivityPeriod: BN;
  message: Uint8Array;
}): Uint8Array {
  const dns = new DepositNowSeedData({
    depositor: depositData.depositor.toBuffer(),
    recipient: depositData.recipient.toBuffer(),
    inputToken: depositData.inputToken.toBuffer(),
    outputToken: depositData.outputToken.toBuffer(),
    inputAmount: depositData.inputAmount,
    outputAmount: depositData.outputAmount,
    destinationChainId: depositData.destinationChainId,
    exclusiveRelayer: depositData.exclusiveRelayer.toBuffer(),
    fillDeadlineOffset: depositData.fillDeadlineOffset,
    exclusivityPeriod: depositData.exclusivityPeriod,
    message: depositData.message,
  });

  return deriveSeedHash(depositNowSeedSchema, dns);
}

/**
 * Returns the delegate PDA for `deposit_now(...)`
 */
export function getDepositNowPda(
  depositData: Parameters<typeof getDepositNowSeedHash>[0],
  programId: PublicKey
): PublicKey {
  const seedHash = getDepositNowSeedHash(depositData);
  const [pda] = PublicKey.findProgramAddressSync([Buffer.from("delegate"), seedHash], programId);
  return pda;
}

/**
 * Fill Delegate Seed Data
 */
class FillDelegateSeedData {
  relayHash: Uint8Array;
  repaymentChainId: BN;
  repaymentAddress: Uint8Array;
  constructor(fields: { relayHash: Uint8Array; repaymentChainId: BN; repaymentAddress: Uint8Array }) {
    this.relayHash = fields.relayHash;
    this.repaymentChainId = fields.repaymentChainId;
    this.repaymentAddress = fields.repaymentAddress;
  }
}

/**
 * Borsh schema for FillDelegateSeedData
 */
const fillDelegateSeedSchema = new Map<any, any>([
  [
    FillDelegateSeedData,
    {
      kind: "struct",
      fields: [
        ["relayHash", [32]],
        ["repaymentChainId", "u64"],
        ["repaymentAddress", [32]],
      ],
    },
  ],
]);

/**
 * Returns the fill delegate seed hash.
 */

export function getFillRelayDelegateSeedHash(
  relayHash: Uint8Array,
  repaymentChainId: BN,
  repaymentAddress: PublicKey
): Uint8Array {
  const ds = new FillDelegateSeedData({
    relayHash,
    repaymentChainId,
    repaymentAddress: repaymentAddress.toBuffer(),
  });

  return deriveSeedHash(fillDelegateSeedSchema, ds);
}

/**
 * Returns the fill delegate PDA.
 */
export function getFillRelayDelegatePda(
  relayHash: Uint8Array,
  repaymentChainId: BN,
  repaymentAddress: PublicKey,
  programId: PublicKey
): { seedHash: Uint8Array; pda: PublicKey } {
  const seedHash = getFillRelayDelegateSeedHash(relayHash, repaymentChainId, repaymentAddress);
  const [pda] = PublicKey.findProgramAddressSync([Buffer.from("delegate"), seedHash], programId);

  return { seedHash, pda };
}
