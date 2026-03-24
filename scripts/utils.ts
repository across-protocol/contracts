import { ethers } from "ethers";
import * as dotenv from "dotenv";
dotenv.config();

export function getProvider(rpcUrl?: string): ethers.providers.JsonRpcProvider {
  return new ethers.providers.JsonRpcProvider(rpcUrl || process.env.NODE_URL);
}

export function getSigner(provider: ethers.providers.Provider): ethers.Wallet {
  const mnemonic = process.env.MNEMONIC;
  if (!mnemonic) throw new Error("MNEMONIC env var required");
  return ethers.Wallet.fromMnemonic(mnemonic).connect(provider);
}

export async function getChainId(provider: ethers.providers.Provider): Promise<number> {
  const network = await provider.getNetwork();
  return network.chainId;
}
