import { BN } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { BigNumber } from "ethers";

/**
 * Relayer Refund Interfaces
 */
export interface RelayerRefundLeaf {
  isSolana: boolean;
  amountToReturn: BigNumber;
  chainId: BigNumber;
  refundAmounts: BigNumber[];
  leafId: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
}

export interface RelayerRefundLeafSolana {
  isSolana: boolean;
  amountToReturn: BN;
  chainId: BN;
  refundAmounts: BN[];
  leafId: BN;
  mintPublicKey: PublicKey;
  refundAddresses: PublicKey[];
}

export type RelayerRefundLeafType = RelayerRefundLeaf | RelayerRefundLeafSolana;

/**
 * Slow Fill Leaf Interface
 */
export interface SlowFillLeaf {
  relayData: RelayData;
  chainId: BN;
  updatedOutputAmount: BN;
}

/**
 * Relay Data Interface
 */
export type RelayData = {
  depositor: PublicKey;
  recipient: PublicKey;
  exclusiveRelayer: PublicKey;
  inputToken: PublicKey;
  outputToken: PublicKey;
  inputAmount: BN;
  outputAmount: BN;
  originChainId: BN;
  depositId: number[];
  fillDeadline: number;
  exclusivityDeadline: number;
  message: Buffer;
};

/**
 * Deposit Data Interfaces
 */
export interface DepositData {
  depositor: PublicKey | null;
  recipient: PublicKey;
  inputToken: PublicKey | null;
  outputToken: PublicKey;
  inputAmount: BN;
  outputAmount: BN;
  destinationChainId: BN;
  exclusiveRelayer: PublicKey;
  quoteTimestamp: BN;
  fillDeadline: BN;
  exclusivityParameter: BN;
  message: Buffer;
}

export type DepositDataValues = [
  PublicKey,
  PublicKey,
  PublicKey,
  PublicKey,
  BN,
  BN,
  BN,
  PublicKey,
  number,
  number,
  number,
  Buffer
];

/**
 * Fill Data Interfaces
 */
export type FillDataValues = [number[], RelayData, BN, PublicKey];

export type FillDataParams = [number[], RelayData | null, BN | null, PublicKey | null];

/**
 * Request V3 Slow Fill Data Interfaces
 */
export type RequestV3SlowFillDataValues = [number[], RelayData];

export type RequestV3SlowFillDataParams = [number[], RelayData | null];

/**
 * Execute V3 Slow Relay Leaf Data Interfaces
 */
export type ExecuteV3SlowRelayLeafDataValues = [number[], SlowFillLeaf, number, number[][]];

export type ExecuteV3SlowRelayLeafDataParams = [number[], SlowFillLeaf | null, number | null, number[][] | null];

/**
 * Across+ Message Interface
 */
export type AcrossPlusMessage = {
  handler: PublicKey;
  readOnlyLen: number;
  valueAmount: BN;
  accounts: PublicKey[];
  handlerMessage: Buffer;
};

/**
 * Event Type Interface
 */
export interface EventType {
  program: PublicKey;
  data: any;
  name: string;
  slot: number;
  confirmationStatus: string;
  blockTime: number;
  signature: string;
}
