import { MerkleTree } from "@uma/common";
import { BigNumber, ethers } from "ethers";

export function constructSimpleRebalanceTree(l1TokenAddress: string, netSendAmount: BigNumber, chainId: BigNumber) {
  const poolRebalanceLeaf = {
    chainId,
    groupIndex: BigNumber.from(1), // Not 0 as this script is not relaying root bundles, only sending tokens to spoke.
    bundleLpFees: [BigNumber.from(0)],
    netSendAmounts: [netSendAmount],
    runningBalances: [netSendAmount],
    leafId: BigNumber.from(0),
    l1Tokens: [l1TokenAddress],
  };

  const rebalanceParamType =
    "tuple( uint256 chainId, uint256[] bundleLpFees, int256[] netSendAmounts, int256[] runningBalances, uint256 groupIndex, uint8 leafId, address[] l1Tokens )";
  const rebalanceHashFn = (input: any) =>
    ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([rebalanceParamType], [input]));

  const poolRebalanceTree = new MerkleTree([poolRebalanceLeaf], rebalanceHashFn);
  return { poolRebalanceLeaf, poolRebalanceTree };
}
