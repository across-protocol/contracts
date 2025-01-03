import { AnchorProvider } from "@coral-xyz/anchor";
import { BigNumber } from "@ethersproject/bignumber";
import { ethers } from "ethers";

/**
 * Returns the chainId for a given solana cluster.
 */
export const getSolanaChainId = (cluster: "devnet" | "mainnet"): BigNumber => {
  return BigNumber.from(
    BigInt(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`solana-${cluster}`))) & BigInt("0xFFFFFFFFFFFFFFFF")
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
