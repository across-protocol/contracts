import { AnchorProvider, BN } from "@coral-xyz/anchor";
import { BigNumber } from "@ethersproject/bignumber";
import { ethers } from "ethers";
import { DepositData } from "../../types/svm";
import { PublicKey } from "@solana/web3.js";

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
 * Returns the delegate PDA for a deposit.
 */
export const getDepositDelegatePda = (depositData: DepositData, stateSeed: BN, programId: PublicKey) => {
  const raw = Buffer.concat([
    depositData.inputToken!.toBytes(),
    depositData.outputToken.toBytes(),
    depositData.inputAmount.toArrayLike(Buffer, "le", 8),
    depositData.outputAmount.toArrayLike(Buffer, "le", 8),
    depositData.destinationChainId.toArrayLike(Buffer, "le", 8),
  ]);
  const hashHex = ethers.utils.keccak256(raw);
  const seedHash = Buffer.from(hashHex.slice(2), "hex");
  return PublicKey.findProgramAddressSync(
    [Buffer.from("delegate"), stateSeed.toArrayLike(Buffer, "le", 8), seedHash],
    programId
  )[0];
};

/**
 * Returns the delegate PDA for a fill relay.
 */
export const getFillRelayDelegatePda = (relayHash: Uint8Array, stateSeed: BN, programId: PublicKey) => {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("delegate"), stateSeed.toArrayLike(Buffer, "le", 8), relayHash],
    programId
  )[0];
};
