import { BigNumber, Contract } from "./utils";
import { MerkleTree } from "../utils/MerkleTree";
import { RelayData } from "./fixtures/SpokePool.Fixture";
export interface PoolRebalanceLeaf {
  chainId: BigNumber;
  bundleLpFees: BigNumber[];
  netSendAmounts: BigNumber[];
  runningBalances: BigNumber[];
  leafId: BigNumber;
  l1Tokens: string[];
}
export interface RelayerRefundLeaf {
  amountToReturn: BigNumber;
  chainId: BigNumber;
  refundAmounts: BigNumber[];
  leafId: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
}
export declare function buildRelayerRefundTree(
  relayerRefundLeafs: RelayerRefundLeaf[]
): Promise<MerkleTree<RelayerRefundLeaf>>;
export declare function buildRelayerRefundLeafs(
  destinationChainIds: number[],
  amountsToReturn: BigNumber[],
  l2Tokens: string[],
  refundAddresses: string[][],
  refundAmounts: BigNumber[][]
): RelayerRefundLeaf[];
export declare function buildPoolRebalanceLeafTree(
  poolRebalanceLeafs: PoolRebalanceLeaf[]
): Promise<MerkleTree<PoolRebalanceLeaf>>;
export declare function buildPoolRebalanceLeafs(
  destinationChainIds: number[],
  l1Tokens: string[][],
  bundleLpFees: BigNumber[][],
  netSendAmounts: BigNumber[][],
  runningBalances: BigNumber[][]
): PoolRebalanceLeaf[];
export declare function constructSingleRelayerRefundTree(
  l2Token: Contract | String,
  destinationChainId: number
): Promise<{
  leafs: RelayerRefundLeaf[];
  tree: MerkleTree<RelayerRefundLeaf>;
}>;
export declare function constructSingleChainTree(
  token: string,
  scalingSize?: number,
  repaymentChain?: number
): Promise<{
  tokensSendToL2: BigNumber;
  realizedLpFees: BigNumber;
  leafs: PoolRebalanceLeaf[];
  tree: MerkleTree<PoolRebalanceLeaf>;
}>;
export declare function buildSlowRelayTree(relays: RelayData[]): Promise<MerkleTree<RelayData>>;
